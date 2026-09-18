/**
 * MERCAMIO - Describir un fallo de entrega
 * -----------------------------------------
 * Cuerpo del nodo Code "Describir el fallo".
 *
 * Por que existe: cuando el envio por WhatsApp falla, el proveedor que escribio
 * recibe silencio. No hay aviso, no hay correo, y el unico rastro queda en una
 * lista de ejecuciones de n8n que nadie mira. Con el numero de prueba el caso
 * mas comun es "Recipient phone number not in allowed list"; en produccion
 * seran cuota, red o un token revocado.
 *
 * Este nodo arma una fila para la pestana "Fallos" de la misma hoja donde ya
 * caen las solicitudes, que es el unico sitio que contabilidad abre de verdad.
 *
 * Lo mas valioso de la fila es `mensaje_no_entregado`: permite reenviarlo a
 * mano, que es lo unico que se puede hacer cuando alguien ya escribio y se
 * quedo esperando.
 */

// -------------------------------------------------- de donde sale el error
//
// Esto costo tres intentos, asi que queda escrito.
//
// El nodo cuelga de la salida NORMAL del envio, no de la de error. Con
// onError 'continueErrorOutput' n8n NO expone el error al sandbox del nodo
// Code: el item llega como {"json":{},"pairedItem":{"item":0}} y la causa se
// pierde entera.
//
// Con 'continueRegularOutput' el item llega asi:
//
//   {
//     "json":  { "error": "Bad request - please check your parameters" },
//     "error": { "message": "Bad request - please check your parameters",
//                "description": "Recipient phone number not in allowed list",
//                "name": "NodeApiError", "context": {} },
//     "pairedItem": { "item": 0 }
//   }
//
// O sea: dentro de `json` solo hay una CADENA generica, y el objeto con el
// motivo real de Meta cuelga del ITEM. Hay que mirar el item PRIMERO; al reves,
// todas las filas salen diciendo "Bad request" y no sirven para nada.
//
// Como por esta salida pasan tambien los envios correctos, hay que descartarlos.
const entrada = $input.first() || {};
const fallo = entrada.error || (entrada.json && entrada.json.error) || null;

if (!fallo) {
  // Envio correcto: devolver [] corta la rama sin escribir nada en la hoja.
  return [];
}

let original = {};
try {
  original = $('Motor conversacional - 9 rutas').first().json || {};
}
catch (e) {
  // Si no se puede releer el motor, se registra igual con lo que haya: una
  // fila incompleta sirve mas que ninguna fila.
  original = {};
}

// `message` es el texto generico de n8n y `description` el motivo real de Meta.
// Se conservan los dos, con el especifico delante: el generico indica el tipo
// de fallo HTTP y ayuda cuando no hay descripcion.
const especifico =
  fallo.description ||
  (fallo.cause && fallo.cause.error && fallo.cause.error.message) ||
  (fallo.cause && fallo.cause.message) ||
  (fallo.error && fallo.error.message) ||
  '';

const generico = (typeof fallo === 'string' ? fallo : fallo.message) || '';

const mensajeError =
  [especifico, generico].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(' | ') ||
  // Ultimo recurso: volcar lo que haya llegado. n8n ha movido el error de sitio
  // entre versiones y una celda fea con el objeto entero se puede leer; un
  // "Error sin mensaje" obliga a reproducir el fallo para diagnosticarlo.
  (() => {
    for (const obj of [fallo, entrada]) {
      try {
        const crudo = JSON.stringify(obj);
        if (crudo && crudo !== '{}' && crudo !== 'null') {
          return 'sin campo conocido, crudo: ' + crudo.slice(0, 400);
        }
      }
      catch (e) {
        // Referencias circulares: se prueba con el siguiente candidato.
      }
    }
    return '';
  })() ||
  'Error sin mensaje ni contenido';

const codigo =
  (fallo.context && fallo.context.messageCode) ||
  (fallo.cause && fallo.cause.error && fallo.cause.error.code) ||
  (fallo.error && fallo.error.code) ||
  fallo.httpCode ||
  '';

const ticket = original.ticket || {};

return [{
  json: {
    fecha: new Date().toISOString(),
    session_id: original.session_id || original.waTo || '',
    telefono: original.waTo || '',
    nodo: 'Responder por WhatsApp Business',
    error: codigo ? `[${codigo}] ${mensajeError}` : mensajeError,
    ticket_id: ticket.ticket_id || '',
    mensaje_no_entregado: original.output || '',
  },
}];
