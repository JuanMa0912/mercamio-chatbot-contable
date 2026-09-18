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
return [{ json: $('Motor conversacional - 9 rutas').first().json }];
