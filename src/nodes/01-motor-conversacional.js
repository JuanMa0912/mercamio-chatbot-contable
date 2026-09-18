/**
 * MERCAMIO - Motor conversacional del chatbot contable (9 rutas)
 * ---------------------------------------------------------------
 * Este archivo es el CUERPO EXACTO del nodo Code "Motor conversacional".
 * No se importa con require(): scripts/build-workflow.mjs lo inyecta en el
 * JSON del workflow y tests/harness.mjs lo ejecuta con los globales de n8n
 * simulados. Una sola fuente de verdad para produccion y para las pruebas.
 *
 * Contrato de salida (un item):
 *   { message_id, sessionId, waTo, businessPhoneNumberId, action, output,
 *     has_ticket (boolean), ticket (object, {} si no hay), estado_sesion,
 *     ruta, es_simulacion }
 *
 * Devuelve [] (array vacio) para descartar el evento: n8n detiene la rama y
 * no ejecuta ningun nodo posterior. Se usa para callbacks de estado de Meta y
 * para webhooks reintentados.
 */

// --------------------------- utilidades de entorno ---------------------------
// $env puede estar bloqueado (N8N_BLOCK_ENV_ACCESS_IN_NODE=true): leerlo nunca
// debe tumbar la ejecucion.
const env = (key, fallback) => {
  try {
    const raw = $env[key];
    return raw === undefined || raw === null || String(raw).trim() === '' ? fallback : raw;
  } catch (error) {
    return fallback;
  }
};

const SESSION_TTL_MIN = Number(env('MERCAMIO_SESSION_TTL_MIN', 60)) || 60;
const MAX_SESSIONS = Number(env('MERCAMIO_MAX_SESSIONS', 500)) || 500;
const MAX_SEEN_IDS = 300;
const WHATSAPP_MAX_CHARS = 4000; // el limite real de Meta es 4096
const PORTAL = env('MERCAMIO_PORTAL_URL', 'https://mercamio.com.co/proveedores/');

// --------------------------- entrada y normalizacion -------------------------
const input = $input.first().json;
const payload = input.body ?? input;
// El WhatsApp Trigger de n8n entrega ya el objeto changes[0].value aplanado.
// Se admite tambien el webhook crudo de Meta (entry[0].changes[0].value).
const value = payload.entry?.[0]?.changes?.[0]?.value ?? payload;

let message = value.messages?.[0] ?? payload.messages?.[0] ?? null;
let esSimulacion = false;

// Entrada del simulador local: { "from": "573001112233", "text": "hola" }
if (!message) {
  const textoSimulado = payload.text ?? payload.message ?? payload.chatInput ?? payload.mensaje;
  if (textoSimulado !== undefined && textoSimulado !== null && String(textoSimulado).trim() !== '') {
    esSimulacion = true;
    message = {
      id: String(payload.message_id ?? 'sim-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8)),
      from: String(payload.from ?? payload.waTo ?? 'simulador'),
      type: 'text',
      text: { body: String(textoSimulado) },
    };
  }
}

// GUARDA 1: callbacks de estado (sent/delivered/read/failed) y cualquier evento
// sin mensaje entrante. Sin esta guarda, cada respuesta que envia el bot
// re-dispara el flujo con waTo vacio y corrompe una sesion compartida.
if (!message) {
  return [];
}

const contact = value.contacts?.[0] ?? payload.contacts?.[0] ?? {};

const waTo = String(message.from ?? contact.wa_id ?? payload.waTo ?? '').replace(/\D/g, '');
const businessPhoneNumberId = String(
  value.metadata?.phone_number_id ??
  payload.metadata?.phone_number_id ??
  payload.businessPhoneNumberId ??
  env('WHATSAPP_PHONE_NUMBER_ID', '')
);

const sessionId = String(waTo || payload.sessionId || (esSimulacion ? 'simulador' : '') || 'sin-remitente');

// --------------------------- estado persistente ------------------------------
// OJO: $getWorkflowStaticData solo se GUARDA en ejecuciones de produccion
// (workflow activo). Con "Execute workflow" los cambios se descartan y el bot
// parece reiniciarse en cada mensaje. Ver docs/06-pruebas.md.
const store = $getWorkflowStaticData('global');
store.sessions ??= {};
store.seen ??= [];

// GUARDA 2: idempotencia. Meta reintenta el webhook si no recibe 200 a tiempo;
// sin esto la conversacion avanza dos pasos con un solo mensaje del usuario.
const messageId = String(message.id ?? '');
if (messageId && store.seen.includes(messageId)) {
  return [];
}
if (messageId) {
  store.seen.push(messageId);
  if (store.seen.length > MAX_SEEN_IDS) {
    store.seen = store.seen.slice(-MAX_SEEN_IDS);
  }
}

// Purga por TTL: una sesion abandonada no debe revivir a medio camino dias
// despues, pidiendo un dato sin contexto.
const ahoraMs = Date.now();
const ttlMs = SESSION_TTL_MIN * 60 * 1000;
for (const [id, guardada] of Object.entries(store.sessions)) {
  const marca = Date.parse(guardada?.updatedAt ?? guardada?.startedAt ?? 0);
  if (!Number.isFinite(marca) || ahoraMs - marca > ttlMs) {
    delete store.sessions[id];
  }
}

// Tope de tamano: static data se serializa dentro de la fila del workflow en la
// base de datos y se lee/escribe en CADA ejecucion. Sin tope crece sin limite.
const ids = Object.keys(store.sessions);
if (ids.length > MAX_SESSIONS) {
  ids
    .sort((a, b) => Date.parse(store.sessions[a]?.updatedAt ?? 0) - Date.parse(store.sessions[b]?.updatedAt ?? 0))
    .slice(0, ids.length - MAX_SESSIONS)
    .forEach((id) => delete store.sessions[id]);
}

const nuevaSesion = () => ({ step: 'inicio', data: {}, startedAt: new Date().toISOString() });
let session = store.sessions[sessionId] ?? nuevaSesion();

const save = () => {
  session.updatedAt = new Date().toISOString();
  store.sessions[sessionId] = session;
};

// --------------------------- texto del mensaje -------------------------------
const TIPOS_SOPORTADOS = new Set(['text', 'interactive', 'button']);
const tipoMensaje = String(message.type ?? 'text');

const raw = String(
  message.text?.body ??
  message.button?.text ??
  message.interactive?.button_reply?.title ??
  message.interactive?.button_reply?.id ??
  message.interactive?.list_reply?.title ??
  message.interactive?.list_reply?.id ??
  ''
).trim();

// GUARDA 3: audio, imagen, documento, ubicacion, sticker o reaccion. Antes
// llegaban con raw vacio y empujaban la maquina de estados sin contenido.
if (!TIPOS_SOPORTADOS.has(tipoMensaje) || raw === '') {
  save();
  return [{
    json: {
      message_id: messageId,
      sessionId,
      waTo,
      businessPhoneNumberId,
      action: 'NO_SOPORTADO',
      output: 'Por ahora solo puedo leer mensajes de texto. Escribe tu solicitud en texto, por favor.',
      has_ticket: false,
      ticket: {},
      estado_sesion: session.step,
      ruta: session.routeCode ?? null,
      es_simulacion: esSimulacion,
    },
  }];
}

const normalize = (texto = '') => String(texto)
  .normalize('NFD')
  .replace(/[̀-ͯ]/g, '')
  .toLowerCase()
  .trim();

const text = normalize(raw);

// --------------------------- catalogo de rutas -------------------------------
// Los correos reales NO viven en el repositorio: se inyectan por la variable de
// entorno MERCAMIO_ROUTES_JSON (ver .env.example).
const USER_TYPES = {
  Cliente: 'Cliente',
  Proveedor: 'Proveedor de mercancias',
  Acreedor: 'Acreedor de servicios',
};

const fieldLabels = {
  correo: 'correo electronico',
  identificacion: 'numero de identificacion o NIT',
  numero_factura: 'numero de la factura',
  comprobante: 'comprobante o numero de radicacion',
  tipo_certificado: 'tipo de certificado solicitado',
  valor_pagado: 'valor pagado',
  persona_contratante: 'nombre de la persona que contrato el servicio',
};

// `escalate: true` marca las rutas sin responsable definido. La version
// anterior lo deducia buscando la cadena "por confirmar" DENTRO del correo del
// responsable: el dia que se asigna un correo real, la ruta deja de escalar sin
// que nadie lo note. Ahora es un campo explicito.
const routes = {
  CLI_RET: { userKey: 'Cliente', category: 'Devolucion de retenciones', owner: 'retenciones@pendiente.local', sla: 'Por confirmar', required: ['correo'] },
  CLI_CAR: { userKey: 'Cliente', category: 'Consulta de cartera', owner: 'Responsable de cartera por confirmar', escalate: true, sla: 'Por confirmar', required: ['identificacion', 'correo'] },
  PRO_PEN: { userKey: 'Proveedor', category: 'Factura pendiente', owner: 'proveedores.facturas@pendiente.local', sla: '2 dias', required: ['identificacion', 'numero_factura', 'comprobante'] },
  PRO_CER: { userKey: 'Proveedor', category: 'Certificados', owner: 'proveedores.certificados@pendiente.local', sla: 'Por confirmar', required: ['identificacion', 'tipo_certificado'] },
  ACR_DIF: { userKey: 'Acreedor', category: 'Diferencia en valor pagado', owner: 'acreedores.diferencias@pendiente.local', sla: '3 dias', required: ['identificacion', 'numero_factura', 'valor_pagado'] },
  ACR_PEN: { userKey: 'Acreedor', category: 'Factura pendiente', owner: 'Triage contabilidad - responsable por confirmar', escalate: true, sla: 'Por confirmar', required: ['identificacion', 'numero_factura', 'persona_contratante'] },
  ACR_CER: { userKey: 'Acreedor', category: 'Certificados', owner: 'acreedores.certificados@pendiente.local', sla: 'Por confirmar', required: ['identificacion', 'tipo_certificado'] },
};

const overrideRutas = env('MERCAMIO_ROUTES_JSON', '');
if (overrideRutas) {
  try {
    const parsed = typeof overrideRutas === 'string' ? JSON.parse(overrideRutas) : overrideRutas;
    for (const [codigo, parche] of Object.entries(parsed)) {
      if (routes[codigo]) routes[codigo] = { ...routes[codigo], ...parche };
    }
  } catch (error) {
    // Un JSON malformado en la variable no debe tumbar el bot: se usan los
    // valores por defecto y queda el rastro en el log de la ejecucion.
    console.warn('MERCAMIO_ROUTES_JSON invalido, se usan valores por defecto:', error.message);
  }
}

const menus = {
  Cliente: 'Selecciona tu solicitud:\n1. Devolucion de retenciones\n2. Consulta de cartera',
  Proveedor: 'Selecciona tu solicitud:\n1. Pago cancelado\n2. Factura pendiente\n3. Certificados',
  Acreedor: 'Selecciona tu solicitud:\n1. Diferencia en valor pagado\n2. Factura pendiente\n3. Certificados\n4. Pago cancelado',
};

const yes = /^(1|si|sí|acepto|de acuerdo|confirmo)$/i.test(raw);
const no = /^(2|no|no acepto|rechazo)$/i.test(raw);
const validEmail = (valor) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(valor);

const startRoute = (code) => {
  const route = routes[code];
  session.routeCode = code;
  session.userKey = route.userKey;
  session.data.tipo_usuario = USER_TYPES[route.userKey];
  session.data.categoria = route.category;
  session.pendingFields = [...route.required];
  session.currentField = session.pendingFields.shift();
  session.step = 'collecting';
  return 'Para continuar con ' + route.category + ', escribe tu ' + fieldLabels[session.currentField] + '.';
};

// --------------------------- maquina de estados ------------------------------
let output = '';
let action = 'RESPUESTA';
let ticket = null;

if (text === 'reiniciar' || text === 'nuevo') {
  session = nuevaSesion();
}

if (session.step === 'inicio') {
  session.step = 'consentimiento';
  output = 'Hola, soy el asistente contable de MERCAMIO. Para atender tu solicitud necesitamos usar los datos que compartas unicamente para gestion y trazabilidad del caso. Aceptas el tratamiento de datos?\n1. Si, acepto\n2. No acepto';
} else if (session.step === 'consentimiento') {
  if (yes) {
    session.data.consentimiento = true;
    session.data.fecha_consentimiento = new Date().toISOString();
    session.step = 'nombre';
    output = 'Gracias. Cual es tu nombre completo?';
  } else if (no) {
    session.data.consentimiento = false;
    session.step = 'finalizado';
    action = 'CIERRE';
    output = 'Entendido. No solicitaremos mas datos. Puedes comunicarte con el canal de atencion definido por MERCAMIO. Escribe REINICIAR si deseas comenzar de nuevo.';
  } else {
    output = 'Por favor responde 1 para aceptar o 2 para no aceptar.';
  }
} else if (session.step === 'nombre') {
  if (raw.length < 2) {
    output = 'Escribe un nombre valido para continuar.';
  } else {
    session.data.nombre = raw;
    session.step = 'tipo_usuario';
    output = 'Gracias, ' + raw + '. Que tipo de usuario eres?\n1. Cliente\n2. Proveedor de mercancias\n3. Acreedor de servicios';
  }
} else if (session.step === 'tipo_usuario') {
  let userKey = '';
  if (text === '1' || text.includes('cliente')) userKey = 'Cliente';
  else if (text === '2' || text.includes('proveedor')) userKey = 'Proveedor';
  else if (text === '3' || text.includes('acreedor')) userKey = 'Acreedor';

  if (!userKey) {
    output = 'Selecciona 1 Cliente, 2 Proveedor de mercancias o 3 Acreedor de servicios.';
  } else {
    session.userKey = userKey;
    session.data.tipo_usuario = USER_TYPES[userKey];
    session.step = 'categoria';
    output = menus[userKey];
  }
} else if (session.step === 'categoria') {
  const userKey = session.userKey;
  if (userKey === 'Cliente') {
    if (text === '1' || text.includes('retencion')) output = startRoute('CLI_RET');
    else if (text === '2' || text.includes('cartera')) output = startRoute('CLI_CAR');
    else output = menus.Cliente;
  } else if (userKey === 'Proveedor') {
    if (text === '1' || text.includes('pago cancelado')) {
      session.step = 'finalizado';
      action = 'CIERRE';
      output = 'Consulta el estado del pago en el portal de proveedores: ' + PORTAL + '\nSi necesitas atencion humana, escribe REINICIAR y selecciona nuevamente la categoria.';
    } else if (text === '2' || text.includes('factura')) {
      session.step = 'proveedor_radicacion';
      output = 'La factura ya fue radicada?\n1. Si\n2. No';
    } else if (text === '3' || text.includes('certificado')) {
      output = startRoute('PRO_CER');
    } else {
      output = menus.Proveedor;
    }
  } else if (userKey === 'Acreedor') {
    if (text === '1' || text.includes('diferencia')) output = startRoute('ACR_DIF');
    else if (text === '2' || text.includes('factura')) output = startRoute('ACR_PEN');
    else if (text === '3' || text.includes('certificado')) output = startRoute('ACR_CER');
    else if (text === '4' || text.includes('pago cancelado')) {
      session.step = 'finalizado';
      action = 'CIERRE';
      output = 'Consulta el estado del pago en el portal de proveedores: ' + PORTAL + '\nEscribe REINICIAR para realizar otra solicitud.';
    } else {
      output = menus.Acreedor;
    }
  } else {
    // Sesion sin userKey: viene de una version anterior del motor.
    session.step = 'tipo_usuario';
    output = 'Necesito confirmar tu perfil. Que tipo de usuario eres?\n1. Cliente\n2. Proveedor de mercancias\n3. Acreedor de servicios';
  }
} else if (session.step === 'proveedor_radicacion') {
  if (yes) {
    output = startRoute('PRO_PEN');
  } else if (no) {
    session.step = 'finalizado';
    action = 'CIERRE';
    output = 'Primero debes radicar la factura siguiendo las indicaciones del portal: ' + PORTAL + '\nEscribe REINICIAR cuando quieras iniciar una nueva consulta.';
  } else {
    output = 'Responde 1 si ya radicaste la factura o 2 si aun no la has radicado.';
  }
} else if (session.step === 'collecting') {
  const field = session.currentField;
  if (!field) {
    // Defensa: sesion inconsistente tras un cambio de version del motor.
    session.step = 'tipo_usuario';
    output = 'Perdi el hilo de la solicitud. Que tipo de usuario eres?\n1. Cliente\n2. Proveedor de mercancias\n3. Acreedor de servicios';
  } else if (field === 'correo' && !validEmail(raw)) {
    output = 'El correo no parece valido. Escribelo nuevamente, por ejemplo: nombre@empresa.com';
  } else {
    session.data[field] = raw;
    if (session.pendingFields.length) {
      session.currentField = session.pendingFields.shift();
      output = 'Ahora escribe tu ' + fieldLabels[session.currentField] + '.';
    } else {
      const route = routes[session.routeCode];
      const ticketId = 'MCM-' + Date.now().toString().slice(-8);
      // Ticket con esquema FIJO: las columnas de Google Sheets se mapean una a
      // una y no pueden depender de que la ruta haya pedido o no cada campo.
      ticket = {
        ticket_id: ticketId,
        session_id: sessionId,
        fecha_creacion: new Date().toISOString(),
        estado: 'nuevo',
        responsable: route.owner,
        sla: route.sla,
        ruta: session.routeCode,
        tipo_usuario: session.data.tipo_usuario ?? '',
        categoria: session.data.categoria ?? '',
        nombre: session.data.nombre ?? '',
        identificacion: session.data.identificacion ?? '',
        numero_factura: session.data.numero_factura ?? '',
        comprobante: session.data.comprobante ?? '',
        correo: session.data.correo ?? '',
        tipo_certificado: session.data.tipo_certificado ?? '',
        valor_pagado: session.data.valor_pagado ?? '',
        persona_contratante: session.data.persona_contratante ?? '',
        observaciones: session.data.observaciones ?? '',
      };
      // El registro autoritativo del ticket es Google Sheets. La version
      // anterior tambien lo acumulaba en static data (store.tickets): fuga de
      // memoria permanente que nadie leia nunca.
      session.ticketId = ticketId;
      session.step = 'finalizado';
      action = route.escalate === true || String(route.owner).toLowerCase().includes('por confirmar')
        ? 'ESCALAR'
        : 'TICKET';
      output = 'Solicitud registrada con el ticket ' + ticketId + '. Categoria: ' + route.category + '. Tiempo estimado: ' + route.sla + '. Escribe REINICIAR para crear otra solicitud.';
    }
  }
} else {
  output = 'Esta conversacion ya termino. Escribe REINICIAR para crear una nueva solicitud.';
  action = 'CIERRE';
}

// Defensa final: un output vacio hace fallar el envio en la API de Meta con un
// error poco descriptivo (#131009). Nunca debe salir vacio.
if (!output) {
  output = 'No entendi tu mensaje. Escribe REINICIAR para comenzar de nuevo.';
  action = 'FALLBACK';
}
if (output.length > WHATSAPP_MAX_CHARS) {
  output = output.slice(0, WHATSAPP_MAX_CHARS - 3) + '...';
}

save();

return [{
  json: {
    message_id: messageId,
    sessionId,
    waTo,
    businessPhoneNumberId,
    action,
    output,
    // Bandera booleana para el nodo If. La version anterior evaluaba `ticket`
    // con el operador object/empty sobre un valor null, lo que rompe la
    // ejecucion cuando typeValidation esta en strict.
    has_ticket: ticket !== null,
    ticket: ticket ?? {},
    estado_sesion: session.step,
    ruta: session.routeCode ?? null,
    es_simulacion: esSimulacion,
  },
}];
