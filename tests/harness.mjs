/**
 * MERCAMIO - Banco de pruebas del motor conversacional
 * ----------------------------------------------------
 * Ejecuta src/nodes/01-motor-conversacional.js fuera de n8n, simulando los
 * globales que inyecta el nodo Code ($input, $getWorkflowStaticData, $env).
 *
 * Asi el motor se prueba sin Docker, sin Meta y sin Google: si una
 * conversacion completa falla, falla aqui en milisegundos.
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const CUERPO_MOTOR = readFileSync(join(RAIZ, 'src/nodes/01-motor-conversacional.js'), 'utf8');

// El cuerpo del nodo Code tiene `return` en el nivel superior, que es valido
// dentro de una funcion pero no en un modulo. new Function lo envuelve.
const ejecutarMotor = new Function('$input', '$getWorkflowStaticData', '$env', 'console', CUERPO_MOTOR);

/**
 * Crea una conversacion aislada con su propio static data.
 * @param {object} opciones
 * @param {object} [opciones.env] variables de entorno visibles al motor
 * @param {boolean} [opciones.bloquearEnv] simula N8N_BLOCK_ENV_ACCESS_IN_NODE=true
 */
export function nuevaConversacion({ env = {}, bloquearEnv = false, silencioso = true } = {}) {
  const staticData = {};
  let contador = 0;

  const envProxy = bloquearEnv
    ? new Proxy({}, { get() { throw new Error('access to env vars denied'); } })
    : env;

  const consolaFalsa = silencioso
    ? { log() {}, warn() {}, error() {} }
    : console;

  /**
   * Envia un evento crudo (tal como lo entregaria el trigger o el webhook).
   * @returns {Array} los items que devuelve el nodo Code
   */
  const enviarEvento = (json) => {
    const input = { first: () => ({ json }) };
    return ejecutarMotor(input, () => staticData, envProxy, consolaFalsa);
  };

  /**
   * Envia un mensaje de texto de WhatsApp con el shape real de Meta.
   * @returns {object|null} el json del item de salida, o null si se descarto
   */
  const enviar = (texto, { from = '573001112233', phoneNumberId = '111222333', id } = {}) => {
    contador += 1;
    const items = enviarEvento({
      messages: [{ id: id ?? 'wamid.TEST' + contador, from, type: 'text', text: { body: texto } }],
      contacts: [{ wa_id: from, profile: { name: 'Prueba' } }],
      metadata: { display_phone_number: '573000000000', phone_number_id: phoneNumberId },
    });
    return items.length ? items[0].json : null;
  };

  /** Envia un callback de estado (sent/delivered/read) como lo hace Meta. */
  const enviarEstado = (status = 'delivered') => enviarEvento({
    statuses: [{ id: 'wamid.STATUS1', status, timestamp: '1700000000', recipient_id: '573001112233' }],
    metadata: { display_phone_number: '573000000000', phone_number_id: '111222333' },
  });

  /** Envia un mensaje que no es de texto (audio, imagen, etc.). */
  const enviarNoTexto = (type = 'audio') => {
    contador += 1;
    const items = enviarEvento({
      messages: [{ id: 'wamid.MEDIA' + contador, from: '573001112233', type, [type]: { id: 'media-1' } }],
      metadata: { phone_number_id: '111222333' },
    });
    return items.length ? items[0].json : null;
  };

  /** Recorre una lista de mensajes y devuelve todas las respuestas. */
  const guion = (mensajes, opciones) => mensajes.map((m) => enviar(m, opciones));

  return { enviar, enviarEvento, enviarEstado, enviarNoTexto, guion, staticData };
}

/** Guion compartido: consentimiento + nombre. Deja la sesion en tipo_usuario. */
export const PRELUDIO = ['hola', '1', 'Juan Perez'];

// --------------------------------------------------------------------------
// Nodo "Describir el fallo"
// --------------------------------------------------------------------------
// Corre solo cuando el envio por WhatsApp ya ha fallado, asi que en la practica
// se estrena el dia que hay una incidencia: si tiene un error, se descubre
// justo cuando mas falta hacia que funcionara. De ahi que se pruebe aparte.
const CUERPO_FALLO = readFileSync(join(RAIZ, 'src/nodes/03-describir-fallo.js'), 'utf8');
const ejecutarFallo = new Function('$input', '$', 'console', CUERPO_FALLO);

/**
 * Ejecuta el nodo que arma la fila de la pestana "Fallos".
 * @param {object} opciones
 * @param {object} opciones.error      el objeto de error tal como lo entrega n8n
 * @param {object} [opciones.motor]    item del motor; null simula que no se puede releer
 * @param {'real'|'item'|'json'} [opciones.donde]  forma del item que se simula
 * @returns {object|null} el json de la fila, o null si el nodo no registra nada
 */
export function describirFallo({ error, motor = {}, donde = 'real' }) {
  // 'real' reproduce lo que entrega n8n 1.117 con onError
  // 'continueRegularOutput', comprobado contra un fallo de verdad:
  //
  //   { json: { error: "<mensaje generico>" },   <- una CADENA
  //     error: { message, description, ... } }   <- el objeto con el motivo
  //
  // Es una distincion que importa: el objeto util cuelga del item y dentro de
  // json solo hay texto generico. Las otras dos formas cubren cada mitad por
  // separado, para que el nodo siga tolerandolas si n8n las mueve de sitio.
  const itemFallo =
    donde === 'item' ? { json: {}, error }
      : donde === 'json' ? { json: { error } }
        : { json: { error: (error && error.message) || String(error) }, error };
  const $input = { first: () => itemFallo };
  const $ = (nombre) => {
    if (motor === null) throw new Error(`No node called "${nombre}"`);
    return { first: () => ({ json: motor }) };
  };
  const items = ejecutarFallo($input, $, { log() {}, warn() {}, error() {} });
  // Devuelve null cuando el nodo decide que no hay nada que registrar.
  return items.length ? items[0].json : null;
}

/**
 * Simula un envio CORRECTO pasando por el mismo nodo: la respuesta de Meta
 * viaja por la salida normal y no debe generar ninguna fila de fallo.
 * @returns {object|null} null si el nodo descarta el item, como debe
 */
export function describirEnvioCorrecto(respuestaDeMeta = { messaging_product: "whatsapp", messages: [{ id: "wamid.OK" }] }) {
  const $input = { first: () => ({ json: respuestaDeMeta }) };
  const $ = () => ({ first: () => ({ json: {} }) });
  const items = ejecutarFallo($input, $, { log() {}, warn() {}, error() {} });
  return items.length ? items[0].json : null;
}
