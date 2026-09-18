/**
 * MERCAMIO - Pruebas del motor conversacional
 * -------------------------------------------
 *   node --test tests/
 *
 * Cubre las 9 rutas de negocio y, sobre todo, los fallos concretos que tenia
 * la version V06. Cada bloque "regresion" corresponde a un bug real
 * documentado en docs/05-auditoria-workflow.md.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { nuevaConversacion, PRELUDIO } from './harness.mjs';

// Columnas que Google Sheets espera recibir SIEMPRE, sin importar la ruta.
const COLUMNAS_SHEET = [
  'ticket_id', 'fecha_creacion', 'session_id', 'estado', 'tipo_usuario',
  'categoria', 'ruta', 'nombre', 'identificacion', 'numero_factura',
  'comprobante', 'correo', 'tipo_certificado', 'valor_pagado',
  'persona_contratante', 'responsable', 'sla', 'observaciones',
];

/** Recorre un guion completo y devuelve la ultima respuesta. */
const recorrer = (mensajes) => {
  const conv = nuevaConversacion();
  const respuestas = conv.guion([...PRELUDIO, ...mensajes]);
  return { conv, respuestas, ultima: respuestas.at(-1) };
};

// ─────────────────────────────── regresiones V06 ─────────────────────────────
describe('regresiones de la version V06', () => {
  test('BUG-01: has_ticket es siempre booleano y ticket siempre objeto', () => {
    // El If de V06 evaluaba `ticket` con el operador object/empty sobre null,
    // lo que aborta la ejecucion con typeValidation: strict.
    const conv = nuevaConversacion();
    for (const mensaje of ['hola', '1', 'Juan Perez', '1', '1', 'juan@empresa.com']) {
      const r = conv.enviar(mensaje);
      assert.equal(typeof r.has_ticket, 'boolean', 'has_ticket debe ser boolean');
      assert.equal(typeof r.ticket, 'object', 'ticket debe ser objeto');
      assert.notEqual(r.ticket, null, 'ticket nunca debe ser null');
    }
  });

  test('BUG-05: los callbacks de estado de Meta se descartan', () => {
    const conv = nuevaConversacion();
    conv.enviar('hola');
    for (const estado of ['sent', 'delivered', 'read', 'failed']) {
      assert.deepEqual(conv.enviarEstado(estado), [], 'el evento ' + estado + ' debe descartarse');
    }
    // El estado de la conversacion no se movio: el siguiente '1' acepta el
    // consentimiento, no queda desfasado.
    const r = conv.enviar('1');
    assert.equal(r.estado_sesion, 'nombre');
  });

  test('BUG-05b: un evento sin mensaje ni texto no crea sesion basura', () => {
    const conv = nuevaConversacion();
    assert.deepEqual(conv.enviarEvento({ metadata: { phone_number_id: '1' } }), []);
    assert.deepEqual(Object.keys(conv.staticData.sessions ?? {}), []);
  });

  test('BUG-06: un webhook reintentado por Meta no avanza la conversacion', () => {
    const conv = nuevaConversacion();
    const primera = conv.enviar('hola', { id: 'wamid.FIJO' });
    assert.equal(primera.estado_sesion, 'consentimiento');
    // Mismo message.id: Meta reintenta cuando no recibe 200 a tiempo.
    assert.deepEqual(conv.enviarEvento({
      messages: [{ id: 'wamid.FIJO', from: '573001112233', type: 'text', text: { body: 'hola' } }],
      metadata: { phone_number_id: '111222333' },
    }), []);
  });

  test('BUG-07: un audio o imagen no empuja la maquina de estados', () => {
    const conv = nuevaConversacion();
    conv.enviar('hola');
    for (const tipo of ['audio', 'image', 'document', 'sticker', 'location']) {
      const r = conv.enviarNoTexto(tipo);
      assert.equal(r.action, 'NO_SOPORTADO');
      assert.equal(r.estado_sesion, 'consentimiento', 'el paso no debe avanzar con ' + tipo);
    }
  });

  test('BUG-08: cada telefono tiene su propia sesion', () => {
    const conv = nuevaConversacion();
    conv.enviar('hola', { from: '573001112233' });
    conv.enviar('1', { from: '573001112233' });
    // Un segundo usuario empieza desde cero, no hereda el paso del primero.
    const otro = conv.enviar('hola', { from: '573009998888' });
    assert.equal(otro.estado_sesion, 'consentimiento');
    assert.equal(otro.sessionId, '573009998888');
  });

  test('BUG-09: el output nunca sale vacio', () => {
    // Meta rechaza un body vacio con un error opaco. En V06 la rama
    // `categoria` sin tipo de usuario dejaba output = ''.
    const conv = nuevaConversacion();
    conv.staticData.sessions = { '573001112233': { step: 'categoria', data: {}, updatedAt: new Date().toISOString() } };
    const r = conv.enviar('1');
    assert.ok(r.output.length > 0);
  });

  test('BUG-10: static data no crece sin limite', () => {
    const conv = nuevaConversacion({ env: { MERCAMIO_MAX_SESSIONS: '3' } });
    for (let i = 0; i < 10; i += 1) {
      conv.enviar('hola', { from: '5730011122' + String(i).padStart(2, '0') });
    }
    assert.ok(
      Object.keys(conv.staticData.sessions).length <= 4,
      'se esperaban <= 4 sesiones, hay ' + Object.keys(conv.staticData.sessions).length,
    );
    assert.ok(conv.staticData.seen.length <= 300);
    assert.equal(conv.staticData.tickets, undefined, 'store.tickets era una fuga de memoria');
  });

  test('las sesiones expiradas se purgan en vez de revivir a medio camino', () => {
    const conv = nuevaConversacion({ env: { MERCAMIO_SESSION_TTL_MIN: '30' } });
    const hace2horas = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
    conv.staticData.sessions = {
      '573001112233': { step: 'collecting', currentField: 'correo', pendingFields: [], data: {}, updatedAt: hace2horas },
    };
    const r = conv.enviar('hola');
    assert.equal(r.estado_sesion, 'consentimiento', 'debe arrancar de cero, no pedir el correo');
  });

  test('si $env esta bloqueado el motor sigue funcionando', () => {
    // N8N_BLOCK_ENV_ACCESS_IN_NODE=true hace que leer $env lance excepcion.
    const conv = nuevaConversacion({ bloquearEnv: true });
    const r = conv.enviar('hola');
    assert.equal(r.estado_sesion, 'consentimiento');
  });
});

// ─────────────────────────────── las 9 rutas ─────────────────────────────────
describe('rutas que generan ticket', () => {
  const casosTicket = [
    { nombre: 'CLI_RET - Cliente / devolucion de retenciones', pasos: ['1', '1', 'juan@empresa.com'], ruta: 'CLI_RET', action: 'TICKET', campos: { correo: 'juan@empresa.com', tipo_usuario: 'Cliente' } },
    { nombre: 'CLI_CAR - Cliente / consulta de cartera', pasos: ['1', '2', '900123456', 'juan@empresa.com'], ruta: 'CLI_CAR', action: 'ESCALAR', campos: { identificacion: '900123456', correo: 'juan@empresa.com' } },
    { nombre: 'PRO_PEN - Proveedor / factura pendiente ya radicada', pasos: ['2', '2', '1', '900123456', 'FE-1001', 'RAD-55'], ruta: 'PRO_PEN', action: 'TICKET', campos: { numero_factura: 'FE-1001', comprobante: 'RAD-55', tipo_usuario: 'Proveedor de mercancias' } },
    { nombre: 'PRO_CER - Proveedor / certificados', pasos: ['2', '3', '900123456', 'Retencion en la fuente'], ruta: 'PRO_CER', action: 'TICKET', campos: { tipo_certificado: 'Retencion en la fuente' } },
    { nombre: 'ACR_DIF - Acreedor / diferencia en valor pagado', pasos: ['3', '1', '900123456', 'FE-2002', '1500000'], ruta: 'ACR_DIF', action: 'TICKET', campos: { valor_pagado: '1500000', tipo_usuario: 'Acreedor de servicios' } },
    { nombre: 'ACR_PEN - Acreedor / factura pendiente', pasos: ['3', '2', '900123456', 'FE-3003', 'Maria Gomez'], ruta: 'ACR_PEN', action: 'ESCALAR', campos: { persona_contratante: 'Maria Gomez' } },
    { nombre: 'ACR_CER - Acreedor / certificados', pasos: ['3', '3', '900123456', 'Certificado de ingresos'], ruta: 'ACR_CER', action: 'TICKET', campos: { tipo_certificado: 'Certificado de ingresos' } },
  ];

  for (const caso of casosTicket) {
    test(caso.nombre, () => {
      const { ultima } = recorrer(caso.pasos);
      assert.equal(ultima.has_ticket, true, 'la ruta debe terminar en ticket');
      assert.equal(ultima.ruta, caso.ruta);
      assert.equal(ultima.action, caso.action);
      assert.equal(ultima.estado_sesion, 'finalizado');
      assert.match(ultima.ticket.ticket_id, /^MCM-\d{8}$/);
      assert.match(ultima.output, /MCM-\d{8}/, 'el usuario debe recibir su numero de ticket');

      // Contrato con Google Sheets: todas las columnas presentes, sin undefined.
      for (const columna of COLUMNAS_SHEET) {
        assert.ok(columna in ultima.ticket, 'falta la columna ' + columna);
        assert.notEqual(ultima.ticket[columna], undefined, columna + ' no puede ser undefined');
      }
      for (const [campo, esperado] of Object.entries(caso.campos)) {
        assert.equal(ultima.ticket[campo], esperado, 'campo ' + campo);
      }
      assert.equal(ultima.ticket.nombre, 'Juan Perez');
      assert.equal(ultima.ticket.estado, 'nuevo');
    });
  }
});

describe('rutas de cierre sin ticket', () => {
  const casosCierre = [
    { nombre: 'Proveedor / pago cancelado remite al portal', pasos: ['2', '1'] },
    { nombre: 'Acreedor / pago cancelado remite al portal', pasos: ['3', '4'] },
    { nombre: 'Proveedor / factura sin radicar remite al portal', pasos: ['2', '2', '2'] },
  ];

  for (const caso of casosCierre) {
    test(caso.nombre, () => {
      const { ultima } = recorrer(caso.pasos);
      assert.equal(ultima.has_ticket, false);
      assert.equal(ultima.action, 'CIERRE');
      assert.match(ultima.output, /portal/i);
    });
  }

  test('rechazar el tratamiento de datos cierra sin pedir nada mas', () => {
    const conv = nuevaConversacion();
    conv.enviar('hola');
    const r = conv.enviar('2');
    assert.equal(r.action, 'CIERRE');
    assert.equal(r.has_ticket, false);
    assert.equal(conv.staticData.sessions['573001112233'].data.consentimiento, false);
  });
});

// ─────────────────────────── validaciones y control ─────────────────────────
describe('validaciones de entrada', () => {
  test('un correo invalido se rechaza y se vuelve a pedir', () => {
    const conv = nuevaConversacion();
    conv.guion([...PRELUDIO, '1', '1']);
    const malo = conv.enviar('juan-arroba-empresa');
    assert.match(malo.output, /no parece valido/i);
    assert.equal(malo.has_ticket, false);
    const bueno = conv.enviar('juan@empresa.com');
    assert.equal(bueno.has_ticket, true);
  });

  test('una opcion fuera de menu repite el menu sin avanzar', () => {
    const conv = nuevaConversacion();
    conv.guion(PRELUDIO);
    const r = conv.enviar('99');
    assert.match(r.output, /Selecciona 1 Cliente/);
    assert.equal(r.estado_sesion, 'tipo_usuario');
  });

  test('un nombre de un solo caracter se rechaza', () => {
    const conv = nuevaConversacion();
    conv.guion(['hola', '1']);
    const r = conv.enviar('J');
    assert.match(r.output, /nombre valido/i);
    assert.equal(r.estado_sesion, 'nombre');
  });

  test('se aceptan respuestas en palabras, con y sin tildes', () => {
    const conv = nuevaConversacion();
    conv.enviar('hola');
    conv.enviar('si');
    conv.enviar('Ana Lopez');
    const r = conv.enviar('proveedor');
    assert.match(r.output, /Pago cancelado/);
  });

  test('REINICIAR vuelve al principio desde cualquier paso', () => {
    const conv = nuevaConversacion();
    conv.guion([...PRELUDIO, '1', '1']);
    const r = conv.enviar('REINICIAR');
    assert.equal(r.estado_sesion, 'consentimiento');
    assert.equal(r.has_ticket, false);
  });

  test('tras finalizar, el bot no se queda mudo', () => {
    const { conv } = recorrer(['1', '1', 'juan@empresa.com']);
    const r = conv.enviar('y ahora que');
    assert.equal(r.action, 'CIERRE');
    assert.match(r.output, /REINICIAR/);
  });
});

describe('configuracion por variables de entorno', () => {
  test('MERCAMIO_ROUTES_JSON sobreescribe responsable y SLA', () => {
    const conv = nuevaConversacion({
      env: { MERCAMIO_ROUTES_JSON: JSON.stringify({ CLI_RET: { owner: 'responsable.real@ejemplo.test', sla: '1 dia' } }) },
    });
    const ultima = conv.guion([...PRELUDIO, '1', '1', 'juan@empresa.com']).at(-1);
    assert.equal(ultima.ticket.responsable, 'responsable.real@ejemplo.test');
    assert.equal(ultima.ticket.sla, '1 dia');
    assert.match(ultima.output, /1 dia/);
  });

  test('un MERCAMIO_ROUTES_JSON corrupto no tumba el bot', () => {
    const conv = nuevaConversacion({ env: { MERCAMIO_ROUTES_JSON: '{esto no es json' } });
    const ultima = conv.guion([...PRELUDIO, '1', '1', 'juan@empresa.com']).at(-1);
    assert.equal(ultima.has_ticket, true, 'debe caer a los valores por defecto');
  });

  test('MERCAMIO_PORTAL_URL se refleja en los mensajes de cierre', () => {
    const conv = nuevaConversacion({ env: { MERCAMIO_PORTAL_URL: 'https://ejemplo.test/portal' } });
    const ultima = conv.guion([...PRELUDIO, '2', '1']).at(-1);
    assert.match(ultima.output, /ejemplo\.test\/portal/);
  });
});

describe('entrada del simulador local', () => {
  test('acepta { from, text } y lo marca como simulacion', () => {
    const conv = nuevaConversacion();
    const items = conv.enviarEvento({ from: '573001112233', text: 'hola' });
    assert.equal(items.length, 1);
    assert.equal(items[0].json.es_simulacion, true);
    assert.equal(items[0].json.sessionId, '573001112233');
  });

  test('acepta el payload envuelto en body (webhook de n8n)', () => {
    const conv = nuevaConversacion();
    const items = conv.enviarEvento({ body: { from: '573001112233', text: 'hola' } });
    assert.equal(items.length, 1);
    assert.match(items[0].json.output, /asistente contable de MERCAMIO/);
  });

  test('acepta el webhook crudo de Meta (entry/changes/value)', () => {
    const conv = nuevaConversacion();
    const items = conv.enviarEvento({
      body: {
        entry: [{
          changes: [{
            value: {
              metadata: { phone_number_id: '999' },
              messages: [{ id: 'wamid.RAW1', from: '573001112233', type: 'text', text: { body: 'hola' } }],
            },
          }],
        }],
      },
    });
    assert.equal(items.length, 1);
    assert.equal(items[0].json.businessPhoneNumberId, '999');
  });
});
