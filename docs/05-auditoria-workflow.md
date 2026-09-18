# Auditoría del workflow V06 — por qué no funcionaba

Análisis del archivo original `MERCAMIO - ChatBOT contable V06.json` (12 nodos,
`versionId` interno con nombre `V05`). Cada hallazgo indica el efecto observable
y la corrección aplicada en V07.

Los fallos **BUG-01** a **BUG-04** son bloqueantes: con cualquiera de ellos
presente, el bot no puede responder. No es un problema, son cuatro sumados.

---

## Resumen

| ID | Severidad | Componente | Efecto |
|----|-----------|------------|--------|
| BUG-01 | Bloqueante | Nodo `If` | La ejecución aborta. Nunca se envía respuesta. |
| BUG-02 | Bloqueante | Cableado del `If` | Ramas invertidas: Sheets recibe `ticket: null`. |
| BUG-03 | Bloqueante | Cableado del `If` | Respuesta duplicada en WhatsApp. |
| BUG-04 | Bloqueante en pruebas | Estado de sesión | El bot saluda de nuevo en cada mensaje. |
| BUG-05 | Alta | Trigger de WhatsApp | Bucle de auto-disparo y sesión compartida corrupta. |
| BUG-06 | Alta | Idempotencia | Un reintento de Meta avanza dos pasos. |
| BUG-07 | Media | Tipos de mensaje | Un audio o una foto empuja la máquina de estados. |
| BUG-08 | Media | Nodo Sheets | Columnas ausentes según la ruta. |
| BUG-09 | Media | Motor | `output` vacío ⇒ error opaco de la API de Meta. |
| BUG-10 | Media | Estado de sesión | Fuga de memoria permanente en el static data. |
| BUG-11 | Baja | Escalamiento | La condición de escalar depende del texto de un correo. |
| BUG-12 | Baja | Higiene | PII y secretos embebidos en el JSON. |

---

## BUG-01 — El nodo `If` aborta la ejecución

**Configuración original**

```json
{
  "leftValue": "={{ $json.ticket }}",
  "operator": { "type": "object", "operation": "empty" },
  "options": { "typeValidation": "strict", "version": 3 }
}
```

**Qué llega**: el motor termina con `let ticket = null;` y solo lo reemplaza por
un objeto cuando la solicitud se completa. En el resto de los turnos —que son la
mayoría— el `If` recibe `null`.

**Por qué rompe**: con `typeValidation: "strict"` y operador de tipo `object`,
n8n valida el tipo del valor izquierdo antes de comparar. Un `null` no satisface
el tipo `object` y el nodo lanza un error de validación en vez de evaluar la
condición. La ejecución se detiene ahí: no hay Sheets, no hay envío, el usuario
no recibe nada. En el panel de ejecuciones se ve un error en el nodo `If`, no en
el motor, lo que despista el diagnóstico.

**Corrección**: el motor expone una bandera booleana explícita y el `If` la
evalúa.

```js
// src/nodes/01-motor-conversacional.js (final)
has_ticket: ticket !== null,
ticket: ticket ?? {},          // nunca null
```

```json
{ "leftValue": "={{ $json.has_ticket }}",
  "operator": { "type": "boolean", "operation": "true" } }
```

Un booleano no tiene estado indefinido: no hay forma de que la validación
estricta lo rechace. Cubierto por la prueba `BUG-01`.

---

## BUG-02 — Las ramas del `If` están invertidas

**Cableado original** (`connections` del JSON):

```
If ──TRUE──> Preparar respuesta sin ticket
       └────> Append row in sheet1
   ──FALSE─> Recuperar respuesta tras registro
```

La condición TRUE es *"`ticket` está vacío"*, es decir **no hay ticket**. Pero
esa rama alimenta a `Append row in sheet1`, cuyo mapeo de columnas es:

```
ticket_id      = {{ $json.ticket.ticket_id }}
session_id     = {{ $json.ticket.session_id }}
...
```

Con `ticket` vacío, cada expresión lanza `Cannot read properties of null
(reading 'ticket_id')`.

El nombre del nodo de la rama FALSE lo confirma: *"Recuperar respuesta tras
registro"* está pensado para ir **después** del registro en Sheets, pero está
conectado a la rama que nunca pasa por Sheets.

**Consecuencia doble**: el camino sin ticket falla en Sheets, y los tickets
reales **nunca se escriben en la hoja**. La trazabilidad completa del proceso
contable no existía.

**Corrección**:

```
Tiene ticket? ──TRUE──> Registrar solicitud en Sheets ──> Recuperar respuesta ──┐
              ──FALSE─────────────────────────────────────────────────────────> Responder
```

Verificado en el build: `If TRUE -> Registrar solicitud en Sheets`,
`If FALSE -> Responder`, sin solapamiento entre ramas.

---

## BUG-03 — Respuesta duplicada en WhatsApp

La rama TRUE del `If` original tenía **dos** aristas de salida, y una de ellas
volvía a converger:

```
If TRUE ──> Preparar respuesta sin ticket ──> Responder por WhatsApp
        └─> Append row in sheet1 ──────────> Preparar respuesta sin ticket ──> Responder por WhatsApp
```

`Preparar respuesta sin ticket` se ejecuta dos veces en la misma rama, así que
`Responder por WhatsApp` se dispara dos veces. El usuario recibe el mismo
mensaje duplicado.

Esto es distinto de tener dos aristas entrantes desde ramas **excluyentes**: en
V07, `Responder` recibe una arista de la rama FALSE y otra del final de la rama
TRUE, pero solo una de las dos ramas se ejecuta por invocación.

**Corrección**: se eliminaron los nodos `Respuesta y ticket estructurado` y
`Preparar respuesta sin ticket`. El primero solo recopiaba campos que el motor
ya emite; el segundo era un no-op (`return [{ json: $('...').first().json }]`
sobre el nodo inmediatamente anterior). 12 nodos → 8.

---

## BUG-04 — El static data no persiste en ejecuciones de prueba

`$getWorkflowStaticData('global')` es el único almacén de la conversación. n8n
**solo guarda** los cambios del static data en ejecuciones de **producción**
(workflow activo, disparado por su webhook real). En una ejecución lanzada con
*Execute workflow* desde el editor, las modificaciones se descartan al terminar.

**Síntoma**: probando desde el editor, cada mensaje arranca con
`session.step === 'inicio'` y el bot responde siempre el saludo con la pregunta
de consentimiento. Parece que la máquina de estados está rota cuando en realidad
nunca se guardó.

Esto explica buena parte de la sensación de *"no funciona"*: el flujo se probaba
en el único modo en el que es imposible que funcione.

**Corrección**: no es un cambio de código, es un cambio de procedimiento, y está
documentado en tres sitios —una nota adhesiva en el propio canvas,
[06-pruebas.md](06-pruebas.md) y un comentario en el motor. Para probar hay que:

1. Activar el workflow.
2. Usar la URL **de producción** (`/webhook/...`), no la de prueba
   (`/webhook-test/...`).

Y para probar la lógica sin n8n de por medio, `node --test tests/motor.test.mjs`
ejecuta el motor real con el static data simulado en memoria.

---

## BUG-05 — El trigger se auto-dispara con los callbacks de estado

El trigger está suscrito a `updates: ["messages"]`. Ese campo de la API de Meta
entrega dos cosas distintas:

- mensajes entrantes → `value.messages[]`
- acuses de estado de los mensajes **salientes** → `value.statuses[]`
  (`sent`, `delivered`, `read`, `failed`)

El motor V06 no distinguía. Con un acuse de estado:

```js
const message = value.messages?.[0] ?? input.messages?.[0] ?? {};   // {}
const raw = String(message.text?.body ?? ... ?? '').trim();          // ''
const waTo = String(message.from ?? ... ?? '').replace(/\D/g, '');   // ''
const sessionId = String(waTo || ... || 'demo-mercamio');            // 'demo-mercamio'
```

Tres consecuencias encadenadas:

1. **Bucle de retroalimentación**: cada respuesta que envía el bot genera al
   menos tres acuses (`sent`, `delivered`, `read`). Cada uno reentra al flujo.
2. **Sesión compartida corrupta**: todos los acuses, de todos los usuarios,
   caen en la misma sesión `'demo-mercamio'` y la avanzan con texto vacío.
3. **Error en el envío**: se intenta responder a `recipientPhoneNumber: ''`.

**Corrección** — guarda explícita al inicio del motor:

```js
if (!message) {
  return [];    // n8n detiene la rama: ningún nodo posterior se ejecuta
}
```

Devolver un array vacío es la forma limpia de descartar un evento en n8n: no
requiere un nodo `If` adicional ni deja una ejecución marcada como fallida.
Cubierto por las pruebas `BUG-05` y `BUG-05b`.

---

## BUG-06 — Sin idempotencia ante los reintentos de Meta

La API de Meta reintenta la entrega del webhook si no recibe `200` dentro de su
ventana de tiempo. El workflow escribe en Google Sheets y llama a la API de
WhatsApp antes de responder, así que una latencia alta de Google es suficiente
para disparar un reintento.

En V06 un reintento se procesaba como un mensaje nuevo: la conversación
avanzaba dos pasos con una sola respuesta del usuario, y se generaban dos
tickets del mismo caso.

**Corrección**: registro acotado de `message.id` ya procesados.

```js
if (messageId && store.seen.includes(messageId)) return [];
store.seen.push(messageId);
if (store.seen.length > MAX_SEEN_IDS) store.seen = store.seen.slice(-MAX_SEEN_IDS);
```

**Límite conocido**: el registro vive en el static data del workflow, así que
protege ante reintentos de una instancia única. En modo *queue* con varios
workers, dos reintentos simultáneos podrían colarse. Para ese escenario hace
falta un almacén compartido (Redis) — ver *Deuda técnica* al final.

---

## BUG-07 — Los mensajes que no son texto empujan la máquina de estados

Un audio, una foto, un documento, una ubicación, un sticker o una reacción
llegan con `message.type !== 'text'` y sin `text.body`. En V06 producían
`raw = ''`, lo que se procesaba como una respuesta válida vacía: en el paso
`nombre` fallaba la validación de longitud (aceptable), pero en `collecting`
guardaba el dato como cadena vacía y **avanzaba al siguiente campo**. El ticket
quedaba con campos obligatorios en blanco.

**Corrección**: lista blanca de tipos y respuesta explícita sin avanzar el paso.

```js
const TIPOS_SOPORTADOS = new Set(['text', 'interactive', 'button']);
if (!TIPOS_SOPORTADOS.has(tipoMensaje) || raw === '') {
  save();
  return [{ json: { ..., action: 'NO_SOPORTADO', output: 'Por ahora solo puedo leer mensajes de texto...' } }];
}
```

Se responde en vez de descartar: el usuario que manda una foto merece saber por
qué no pasa nada.

---

## BUG-08 — El ticket tenía forma variable

En V06 el ticket se construía con `...session.data`, que contiene solo los
campos que **esa ruta** pidió:

```js
ticket = { ticket_id, session_id, ..., ...session.data };
```

La ruta `CLI_RET` solo pide `correo`, así que el ticket no tenía
`identificacion`, `numero_factura`, etc. El nodo de Sheets lo compensaba con
`?? ""` en cada columna, lo que funciona, pero deja el contrato con la hoja
dependiendo de 18 expresiones sueltas: añadir un campo en una ruta y olvidar la
columna produce una pérdida de dato silenciosa.

**Corrección**: el ticket se construye con **esquema fijo**, con las 18 claves
siempre presentes y por defecto `''`. La prueba de cada ruta verifica que las 18
columnas existen y que ninguna es `undefined`.

---

## BUG-09 — `output` podía salir vacío

En la rama `categoria`, si `session.data.tipo_usuario` no coincidía con
`'Cliente'`, `'Proveedor'` ni `'Acreedor'` —posible con una sesión heredada de
una versión anterior del motor— ninguna condición asignaba `output`, que se
enviaba como `''`. La API de Meta rechaza un cuerpo de texto vacío con un error
poco descriptivo.

**Corrección**: rama `else` explícita que reencamina al paso de tipo de usuario,
más una red de seguridad al final del motor:

```js
if (!output) { output = 'No entendi tu mensaje. Escribe REINICIAR...'; action = 'FALLBACK'; }
if (output.length > WHATSAPP_MAX_CHARS) output = output.slice(0, WHATSAPP_MAX_CHARS - 3) + '...';
```

Se añadió también el truncado: el límite de Meta es 4096 caracteres.

---

## BUG-10 — Fuga de memoria en el static data

Tres problemas acumulativos en V06:

```js
store.sessions[sessionId] = session;   // sin caducidad
store.tickets ??= [];
store.tickets.push(ticket);            // crece para siempre, nadie lo lee
```

1. **Sin TTL**: una conversación abandonada a medias revive días después. El
   usuario escribe "hola" y el bot responde *"Ahora escribe tu número de
   factura"*, sin contexto.
2. **Sin tope**: el static data se serializa dentro de la fila del workflow en
   la base de datos y se lee y escribe **en cada ejecución**. Crece sin límite y
   degrada progresivamente cada mensaje.
3. **`store.tickets`**: copia completa de cada ticket generado, acumulada
   indefinidamente. Ninguna parte del flujo la lee — el registro autoritativo es
   Google Sheets.

**Corrección**: TTL configurable (`MERCAMIO_SESSION_TTL_MIN`, 60 min por
defecto), tope de sesiones con desalojo de las más antiguas
(`MERCAMIO_MAX_SESSIONS`, 500) y eliminación de `store.tickets`.

---

## BUG-11 — El escalamiento dependía del texto de un correo

```js
action = route.owner.includes('por confirmar') ? 'ESCALAR' : 'TICKET';
```

La decisión de escalar un caso se tomaba buscando una subcadena dentro del campo
del responsable. El día que alguien asigna un correo real a `CLI_CAR`, esa ruta
deja de escalar **sin que nadie lo note**: no hay error, solo un caso que ya no
se marca.

**Corrección**: campo explícito `escalate: true` en el catálogo de rutas, con la
comprobación de subcadena conservada como red de seguridad para no cambiar el
comportamiento de las rutas existentes.

---

## BUG-12 — PII y secretos embebidos en el JSON

El JSON original contiene, en texto plano:

- 5 direcciones de correo internas de empleados de contabilidad
- el ID de la hoja de cálculo (44 caracteres)
- 3 identificadores de credenciales de la instancia n8n
  (referencias internas de 16 caracteres a las credenciales de WhatsApp Trigger,
  WhatsApp API y Google Sheets)
- el `instanceId` de la instancia

Para un repositorio público esto es una exposición de datos personales del
equipo y de un documento de Drive, permanente e indexable.

**Corrección**: la configuración sensible sale del código y entra por variables
de entorno (`MERCAMIO_ROUTES_JSON`, `MERCAMIO_SHEET_ID`), definidas en `.env`,
que está en `.gitignore`. El JSON versionado lleva marcadores
`@pendiente.local` y referencias `$env`. Los valores reales viven solo en la
máquina local.

Ver [07-privacidad-y-repo-publico.md](07-privacidad-y-repo-publico.md).

---

## Deuda técnica pendiente

Cosas que **no** se corrigieron, con el criterio de por qué.

### 1. El estado sigue en el static data del workflow

Es la limitación de diseño más importante que queda.

`$getWorkflowStaticData` funciona para una instancia única de n8n, que es el
escenario local de este repositorio. No sirve si se escala:

- En modo *queue* con varios workers, dos mensajes concurrentes del mismo
  usuario pueden leer el mismo estado y escribirse encima (*lost update*).
- El registro de idempotencia no es compartido entre workers.
- Cada ejecución serializa y deserializa el mapa completo de sesiones.

**Migración cuando haga falta**: Redis con un hash por `sessionId` y `SETNX` con
TTL para el registro de `message.id`. n8n trae el nodo Redis de fábrica. Son dos
nodos más y reemplazar las llamadas a `store` — no es una reescritura, pero
tampoco es gratis, y para volumen de una instancia local no aporta nada.

**Umbral para decidir**: hacerlo antes de pasar a modo *queue* o si se superan
~50 conversaciones concurrentes.

### 2. La ventana de 24 horas de WhatsApp

La API de Meta solo permite mensajes libres dentro de las 24 horas siguientes al
último mensaje del usuario. Pasado ese plazo hay que usar una plantilla
aprobada. El flujo es reactivo, así que hoy no le afecta — pero cualquier
notificación de seguimiento ("tu ticket se resolvió") **fallará** con el error
`#131047` si no se implementa con plantillas. No está resuelto porque no está
en el alcance actual.

### 3. Los tickets no se releen

Nada consulta el estado de un ticket. Si un usuario escribe "¿cómo va mi
MCM-12345678?", el bot no sabe responder. Requiere lectura de Google Sheets y un
paso nuevo en la máquina de estados.

### 4. Sin control de reingreso

Un usuario que ya tiene un ticket abierto puede crear otro idéntico. No hay
comprobación de duplicados por `identificacion` + `ruta`.

### 5. Consentimiento sin registro auditable

`session.data.consentimiento` y `fecha_consentimiento` se guardan en la sesión,
pero **no se escriben en la hoja** y la sesión caduca. Para un flujo que trata
datos personales bajo la Ley 1581 de 2012 (Colombia), la prueba del
consentimiento debería ser persistente. Recomendación concreta: añadir dos
columnas `consentimiento` y `fecha_consentimiento` a la hoja `Solicitudes` y a
`sheets/plantilla-solicitudes.csv`. No se hizo porque cambia el esquema de una
hoja que ya está en uso, y esa es una decisión de negocio.
