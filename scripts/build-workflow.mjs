#!/usr/bin/env node
/**
 * MERCAMIO - Generador de los workflows de n8n
 * --------------------------------------------
 * Ensambla los JSON importables a n8n inyectando el codigo real desde
 * src/nodes/*.js. El codigo del bot se escribe, se lee y se prueba como
 * JavaScript normal; el JSON del workflow es un artefacto derivado.
 *
 *   node scripts/build-workflow.mjs
 *
 * Genera:
 *   workflows/MERCAMIO-chatbot-contable-v07-whatsapp.json   (produccion)
 *   workflows/MERCAMIO-chatbot-contable-v07-simulador.json  (pruebas locales)
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const leer = (ruta) => readFileSync(join(RAIZ, ruta), 'utf8');

const MOTOR = leer('src/nodes/01-motor-conversacional.js');
const RECUPERAR = leer('src/nodes/02-recuperar-respuesta.js');
const CHAT_HTML = leer('src/ui/chat.html');

// El HTML se entrega como cadena literal en el nodo Respond to Webhook. n8n solo
// evalua expresiones en campos que EMPIEZAN por '=', asi que un literal es
// seguro. Aun asi se comprueba que no haya '{{' por si alguien cambia el modo
// del campo mas adelante.
if (CHAT_HTML.includes('{{')) {
  throw new Error('src/ui/chat.html contiene "{{": n8n lo interpretaria como expresion.');
}

const NOMBRE_MOTOR = 'Motor conversacional - 9 rutas';

// Lee una clave de .env en tiempo de BUILD. El build corre en el host, donde
// .env no esta cargado en el entorno, asi que hay que leer el archivo. Se usa
// solo para decisiones de forma del workflow, nunca para secretos: los valores
// sensibles los resuelve n8n en ejecucion con {{ $env.X }}.
const leerEnv = (clave, porDefecto = '') => {
  let contenido;
  try {
    contenido = leer('.env');
  } catch {
    return porDefecto;
  }
  for (const linea of contenido.split(/\r?\n/)) {
    const m = linea.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (m && m[1] === clave) return m[2].trim().replace(/^["']|["']$/g, '');
  }
  return porDefecto;
};

// Por defecto el simulador NO escribe en Sheets: asi se prueba la conversacion
// sin ninguna credencial de Google. Poniendo MERCAMIO_SIM_SHEETS=true en .env
// el nodo queda activo tambien en el simulador, que es la unica forma de
// validar que los tickets llegan de verdad a la hoja SIN depender de WhatsApp.
// Probar Sheets y WhatsApp a la vez significa dos incognitas en el mismo fallo.
const SIM_ESCRIBE_EN_SHEETS = leerEnv('MERCAMIO_SIM_SHEETS').toLowerCase() === 'true';

// IDs fijos de las credenciales que crea scripts/crear-credenciales-whatsapp.ps1.
// Referenciarlas aqui evita tener que asignarlas a mano en la interfaz cada vez
// que se reimporta el workflow. Si no existen todavia, n8n muestra el nodo con
// la credencial en rojo y la activacion falla con "Node does not have any
// credentials set" — que es el comportamiento correcto: mejor un error claro
// que un workflow que parece activo y no escucha.
const CRED_WA_ENVIAR = { id: 'mercamioWaApi001', name: 'MERCAMIO WhatsApp - enviar' };
const CRED_WA_RECIBIR = { id: 'mercamioWaTrg001', name: 'MERCAMIO WhatsApp - recibir' };

// Credencial de Google Sheets: CUENTA DE SERVICIO, no OAuth2.
//
// MERCAMIO no usa Google Workspace, asi que una app OAuth solo puede tener la
// pantalla de consentimiento en modo Externo. En estado "Testing" Google caduca
// el refresh token a los 7 dias, y como este nodo lleva onError
// 'continueRegularOutput' el bot seguiria entregando numeros de ticket sin
// escribir nada en la hoja: un fallo silencioso una semana despues de arrancar.
//
// Una cuenta de servicio firma su propio JWT: no caduca, no tiene pantalla de
// consentimiento y no depende de ninguna URI de redireccion. Eso ultimo evita
// ademas el choque con scripts/tunel-rapido.ps1, que reescribe WEBHOOK_URL y
// con ella N8N_EDITOR_BASE_URL, de donde n8n deriva el callback de OAuth.
//
// La crea scripts/crear-credencial-sheets.ps1 a partir del JSON de la clave.
const CRED_SHEETS = { id: 'mercamioSheets01', name: 'MERCAMIO Google Sheets' };

// ---------------------------------------------------------------- nodos base
const nodoMotor = (pos) => ({
  parameters: { jsCode: MOTOR },
  id: 'a1000000-0000-4000-8000-000000000001',
  name: NOMBRE_MOTOR,
  type: 'n8n-nodes-base.code',
  typeVersion: 2,
  position: pos,
  // Si el motor lanza una excepcion no controlada, el usuario se queda sin
  // respuesta y sin rastro. Se registra el error y la ejecucion se marca.
  onError: 'stopWorkflow',
  notes: 'Codigo generado desde src/nodes/01-motor-conversacional.js. No editar en la UI: los cambios se pierden en el siguiente build.',
});

const nodoIf = (pos) => ({
  parameters: {
    conditions: {
      options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
      conditions: [
        {
          id: 'b2000000-0000-4000-8000-000000000001',
          leftValue: '={{ $json.has_ticket }}',
          rightValue: '',
          operator: { type: 'boolean', operation: 'true', singleValue: true },
        },
      ],
      combinator: 'and',
    },
    options: {},
  },
  id: 'a1000000-0000-4000-8000-000000000002',
  name: 'Tiene ticket?',
  type: 'n8n-nodes-base.if',
  typeVersion: 2.2,
  position: pos,
  notes: 'TRUE = se completo la solicitud y hay ticket -> se registra en Sheets. FALSE = solo responder.',
});

const nodoSheets = (pos, deshabilitado) => ({
  parameters: {
    // Sin esta linea el nodo asume OAuth2 y reclama una credencial que no existe.
    authentication: 'serviceAccount',
    operation: 'append',
    documentId: {
      __rl: true,
      // El ID de la hoja llega por variable de entorno: no se publica en el repo.
      value: '={{ $env.MERCAMIO_SHEET_ID }}',
      mode: 'id',
    },
    sheetName: { __rl: true, value: 'Solicitudes', mode: 'name' },
    columns: {
      mappingMode: 'defineBelow',
      value: {
        ticket_id: '={{ $json.ticket.ticket_id }}',
        fecha_creacion: '={{ $json.ticket.fecha_creacion }}',
        session_id: '={{ $json.ticket.session_id }}',
        estado: '={{ $json.ticket.estado }}',
        tipo_usuario: '={{ $json.ticket.tipo_usuario }}',
        categoria: '={{ $json.ticket.categoria }}',
        ruta: '={{ $json.ticket.ruta }}',
        nombre: '={{ $json.ticket.nombre }}',
        identificacion: '={{ $json.ticket.identificacion }}',
        numero_factura: '={{ $json.ticket.numero_factura }}',
        comprobante: '={{ $json.ticket.comprobante }}',
        correo: '={{ $json.ticket.correo }}',
        tipo_certificado: '={{ $json.ticket.tipo_certificado }}',
        valor_pagado: '={{ $json.ticket.valor_pagado }}',
        persona_contratante: '={{ $json.ticket.persona_contratante }}',
        responsable: '={{ $json.ticket.responsable }}',
        sla: '={{ $json.ticket.sla }}',
        observaciones: '={{ $json.ticket.observaciones }}',
      },
      matchingColumns: [],
      schema: [
        'ticket_id', 'fecha_creacion', 'session_id', 'estado', 'tipo_usuario',
        'categoria', 'ruta', 'nombre', 'identificacion', 'numero_factura',
        'comprobante', 'correo', 'tipo_certificado', 'valor_pagado',
        'persona_contratante', 'responsable', 'sla', 'observaciones',
      ].map((id) => ({
        id,
        displayName: id,
        required: false,
        defaultMatch: false,
        display: true,
        type: 'string',
        canBeUsedToMatch: true,
      })),
      attemptToConvertTypes: false,
      convertFieldsToString: true,
    },
    options: {},
  },
  id: 'a1000000-0000-4000-8000-000000000003',
  name: 'Registrar solicitud en Sheets',
  type: 'n8n-nodes-base.googleSheets',
  typeVersion: 4.7,
  position: pos,
  credentials: { googleApi: CRED_SHEETS },
  ...(deshabilitado ? { disabled: true } : {}),
  // Si Sheets falla (cuota, permisos, red) el usuario DEBE recibir igual su
  // numero de ticket. El error queda en el log de ejecuciones para reproceso.
  onError: 'continueRegularOutput',
  retryOnFail: true,
  maxTries: 3,
  waitBetweenTries: 2000,
  notes: deshabilitado
    ? 'Deshabilitado en el simulador: permite probar el flujo completo sin credenciales de Google.'
    : 'Requiere la cuenta de servicio (scripts/crear-credencial-sheets.ps1) y MERCAMIO_SHEET_ID. La hoja debe llamarse "Solicitudes" y estar compartida como Editor con el correo del service account.',
});

const nodoRecuperar = (pos) => ({
  parameters: { jsCode: RECUPERAR },
  id: 'a1000000-0000-4000-8000-000000000004',
  name: 'Recuperar respuesta tras registro',
  type: 'n8n-nodes-base.code',
  typeVersion: 2,
  position: pos,
  notes: 'Codigo generado desde src/nodes/02-recuperar-respuesta.js.',
});

const nota = (id, pos, ancho, alto, color, contenido) => ({
  parameters: { content: contenido, height: alto, width: ancho, color },
  id,
  name: 'Nota - ' + id.slice(-4),
  type: 'n8n-nodes-base.stickyNote',
  typeVersion: 1,
  position: pos,
});

// -------------------------------------------------- workflow de PRODUCCION
// El id es FIJO a proposito: 'n8n import:workflow' crea un workflow nuevo si
// no encuentra el id, y ACTUALIZA el existente si lo encuentra. Sin id fijo,
// cada importacion deja un duplicado mas en la instancia.
const workflowWhatsapp = {
  id: 'mercamioWa000001',
  name: 'MERCAMIO - ChatBOT contable V07 (WhatsApp)',
  nodes: [
    {
      parameters: {
        updates: ['messages'],
        options: {
          // Descarta los acuses de estado (sent/delivered/read) DENTRO del nodo,
          // antes de que n8n cree una ejecucion. El valor por defecto del nodo
          // es ['all'], que los deja pasar todos: cada respuesta del bot genera
          // ~3 acuses y por tanto 3 ejecuciones desperdiciadas.
          //
          // La guarda del motor (`if (!message) return []`) se mantiene como
          // segunda linea de defensa: cubre el webhook crudo de Meta y el
          // simulador, que no pasan por este nodo.
          messageStatusUpdates: [],
        },
      },
      id: 'a1000000-0000-4000-8000-000000000010',
      name: 'WhatsApp Business Trigger',
      type: 'n8n-nodes-base.whatsAppTrigger',
      typeVersion: 1,
      position: [-220, 0],
      webhookId: 'mercamio-whatsapp-v07',
      credentials: { whatsAppTriggerApi: CRED_WA_RECIBIR },
      notes: 'Escucha "messages", que incluye tambien callbacks de estado (sent/delivered/read). El motor los descarta. La credencial lleva App ID y App Secret, NO el access token.',
    },
    nodoMotor([0, 0]),
    nodoIf([220, 0]),
    nodoSheets([440, -100], false),
    nodoRecuperar([660, -100]),
    {
      parameters: {
        operation: 'send',
        phoneNumberId: '={{ $json.businessPhoneNumberId }}',
        recipientPhoneNumber: '={{ $json.waTo }}',
        textBody: '={{ $json.output }}',
        additionalFields: {},
      },
      id: 'a1000000-0000-4000-8000-000000000011',
      name: 'Responder por WhatsApp Business',
      type: 'n8n-nodes-base.whatsApp',
      typeVersion: 1.1,
      position: [880, 0],
      credentials: { whatsAppApi: CRED_WA_ENVIAR },
      notes: 'La credencial lleva el access token permanente del Usuario del sistema y el Business Account ID.',
    },
    nota('a1000000-0000-4000-8000-0000000000n1', [-260, -320], 460, 260, 4,
      '## Flujo corregido (V07)\n\n1. El trigger entrega el evento crudo de Meta.\n2. El **motor** descarta callbacks de estado y webhooks repetidos, y decide la respuesta.\n3. El **If** usa la bandera booleana `has_ticket` (antes evaluaba `ticket` como objeto y rompia con `null`).\n4. Solo la rama TRUE escribe en Sheets. Antes estaba invertida.\n5. Una sola ruta llega al envio: antes el mensaje salia duplicado.'),
    nota('a1000000-0000-4000-8000-0000000000n2', [240, -320], 420, 260, 3,
      '## Antes de activar\n\n- Variables `MERCAMIO_SHEET_ID` y `MERCAMIO_ROUTES_JSON` definidas en `.env`.\n- La hoja de calculo tiene la pestana **Solicitudes** con los encabezados de `sheets/plantilla-solicitudes.csv`.\n- `WEBHOOK_URL` apunta a la URL publica del tunel.\n- **El workflow debe quedar ACTIVO**: en modo prueba n8n descarta el static data y el bot saluda de nuevo en cada mensaje.'),
  ],
  pinData: {},
  connections: {
    'WhatsApp Business Trigger': { main: [[{ node: NOMBRE_MOTOR, type: 'main', index: 0 }]] },
    [NOMBRE_MOTOR]: { main: [[{ node: 'Tiene ticket?', type: 'main', index: 0 }]] },
    'Tiene ticket?': {
      main: [
        [{ node: 'Registrar solicitud en Sheets', type: 'main', index: 0 }],
        [{ node: 'Responder por WhatsApp Business', type: 'main', index: 0 }],
      ],
    },
    'Registrar solicitud en Sheets': { main: [[{ node: 'Recuperar respuesta tras registro', type: 'main', index: 0 }]] },
    'Recuperar respuesta tras registro': { main: [[{ node: 'Responder por WhatsApp Business', type: 'main', index: 0 }]] },
  },
  active: false,
  settings: { executionOrder: 'v1', saveExecutionProgress: true, saveDataErrorExecution: 'all', saveDataSuccessExecution: 'all' },
  tags: [],
};

// --------------------------------------------------- workflow SIMULADOR
const workflowSimulador = {
  id: 'mercamioSim00001',
  name: 'MERCAMIO - ChatBOT contable V07 (Simulador local)',
  nodes: [
    {
      parameters: {
        httpMethod: 'POST',
        path: 'mercamio-sim',
        responseMode: 'responseNode',
        options: {},
      },
      id: 'a1000000-0000-4000-8000-000000000020',
      name: 'Webhook simulador',
      type: 'n8n-nodes-base.webhook',
      typeVersion: 2,
      position: [-220, 0],
      webhookId: 'mercamio-sim-v07',
      notes: 'POST { "from": "573001112233", "text": "hola" }. URL de produccion: http://localhost:5678/webhook/mercamio-sim',
    },
    nodoMotor([0, 0]),
    nodoIf([220, 0]),
    nodoSheets([440, -100], !SIM_ESCRIBE_EN_SHEETS),
    nodoRecuperar([660, -100]),
    {
      parameters: { respondWith: 'json', responseBody: '={{ { "respuesta": $json.output, "accion": $json.action, "estado": $json.estado_sesion, "ruta": $json.ruta, "ticket": $json.ticket } }}', options: {} },
      id: 'a1000000-0000-4000-8000-000000000021',
      name: 'Responder al simulador',
      type: 'n8n-nodes-base.respondToWebhook',
      typeVersion: 1.1,
      position: [880, 0],
    },
    // ── Chat web de pruebas ────────────────────────────────────────────────
    // Par de nodos independiente del flujo del bot: sirve la interfaz HTML.
    // Va dentro de este mismo workflow y no en un servidor aparte para que el
    // chat quede en el MISMO ORIGEN que el webhook de mensajes: asi no hay
    // peticiones cruzadas y no hace falta configurar CORS.
    {
      parameters: {
        httpMethod: 'GET',
        path: 'mercamio-chat',
        responseMode: 'responseNode',
        options: {},
      },
      id: 'a1000000-0000-4000-8000-000000000022',
      name: 'Chat de pruebas (interfaz)',
      type: 'n8n-nodes-base.webhook',
      typeVersion: 2,
      position: [-220, 320],
      webhookId: 'mercamio-chat-v07',
      notes: 'Abre http://localhost:5678/webhook/mercamio-chat en el navegador.',
    },
    {
      parameters: {
        respondWith: 'text',
        responseBody: CHAT_HTML,
        options: {
          responseHeaders: {
            entries: [
              { name: 'Content-Type', value: 'text/html; charset=utf-8' },
              // Sin esto el navegador cachea la interfaz y un cambio en
              // src/ui/chat.html no se ve hasta forzar recarga.
              { name: 'Cache-Control', value: 'no-store' },
            ],
          },
        },
      },
      id: 'a1000000-0000-4000-8000-000000000023',
      name: 'Entregar la interfaz',
      type: 'n8n-nodes-base.respondToWebhook',
      typeVersion: 1.1,
      position: [0, 320],
      notes: 'HTML generado desde src/ui/chat.html. No editar aqui.',
    },
    nota('a1000000-0000-4000-8000-0000000000n3', [-260, -320], 700, 260, 5,
      '## Simulador local - sin Meta y sin Google\n\nPrueba el motor de 9 rutas de punta a punta sin cuenta de WhatsApp ni credenciales de Google.\n\n**Chat web (para que lo pruebe contabilidad):**\nhttp://localhost:5678/webhook/mercamio-chat\n\n**Por consola:**\n```\npowershell -File scripts/simular-conversacion.ps1\n```\n\n**El workflow debe estar ACTIVO** y hay que usar la URL de produccion (`/webhook/...`), no la de prueba (`/webhook-test/...`): el static data solo persiste en ejecuciones de produccion. Sin eso el bot saluda en cada mensaje.\n\nEl nodo de Sheets viene deshabilitado; habilitalo cuando quieras probar el registro real.'),
  ],
  pinData: {},
  connections: {
    'Webhook simulador': { main: [[{ node: NOMBRE_MOTOR, type: 'main', index: 0 }]] },
    'Chat de pruebas (interfaz)': { main: [[{ node: 'Entregar la interfaz', type: 'main', index: 0 }]] },
    [NOMBRE_MOTOR]: { main: [[{ node: 'Tiene ticket?', type: 'main', index: 0 }]] },
    'Tiene ticket?': {
      main: [
        [{ node: 'Registrar solicitud en Sheets', type: 'main', index: 0 }],
        [{ node: 'Responder al simulador', type: 'main', index: 0 }],
      ],
    },
    'Registrar solicitud en Sheets': { main: [[{ node: 'Recuperar respuesta tras registro', type: 'main', index: 0 }]] },
    'Recuperar respuesta tras registro': { main: [[{ node: 'Responder al simulador', type: 'main', index: 0 }]] },
  },
  active: false,
  settings: { executionOrder: 'v1', saveExecutionProgress: true, saveDataErrorExecution: 'all', saveDataSuccessExecution: 'all' },
  tags: [],
};

// ------------------------------------------------------------------- escritura
mkdirSync(join(RAIZ, 'workflows'), { recursive: true });

const salidas = [
  ['workflows/MERCAMIO-chatbot-contable-v07-whatsapp.json', workflowWhatsapp],
  ['workflows/MERCAMIO-chatbot-contable-v07-simulador.json', workflowSimulador],
];

for (const [ruta, contenido] of salidas) {
  writeFileSync(join(RAIZ, ruta), JSON.stringify(contenido, null, 2) + '\n', 'utf8');
  console.log('generado  ' + ruta + '  (' + contenido.nodes.length + ' nodos)');
}
