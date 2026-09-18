/**
 * MERCAMIO - Recuperar respuesta tras registrar el ticket
 * -------------------------------------------------------
 * Cuerpo del nodo Code "Recuperar respuesta tras registro".
 *
 * Por que existe: el nodo de Google Sheets devuelve como salida la FILA que
 * acaba de escribir, no el item que recibio. Si se conecta Sheets directo al
 * envio de WhatsApp, el nodo de envio recibe { ticket_id, nombre, ... } y no
 * encuentra ni `output` ni `waTo`, y falla.
 *
 * Este nodo vuelve a leer el item original del motor conversacional.
 */

// El nodo de Sheets lleva onError 'continueRegularOutput' a proposito: si la
// escritura falla, el usuario DEBE recibir igual su numero de ticket. El efecto
// secundario es que el fallo se traga sin dejar rastro, y la ejecucion aparece
// como exitosa: el proveedor se va con un ticket que no existe en ninguna hoja.
//
// No se puede registrar ese fallo en la propia hoja —es justo la que acaba de
// fallar—, asi que al menos se deja en el log de la ejecucion y en la salida
// del contenedor (docker compose logs n8n), que es donde se mira cuando alguien
// reclama por un ticket que nadie encuentra.
const entrada = $input.first();
if (entrada && entrada.json && entrada.json.error) {
  const e = entrada.json.error;
  const motivo = e.message || (e.error && e.error.message) || JSON.stringify(e);
  console.error('FALLO AL REGISTRAR EN SHEETS. El usuario recibira su ticket pero NO quedo en la hoja:', motivo);
}

return [{ json: $('Motor conversacional - 9 rutas').first().json }];
