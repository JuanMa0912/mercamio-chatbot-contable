# 08 — Sin token de Meta: qué se puede hacer

## Lo primero: el token no es el problema

Un token de WhatsApp Cloud API es **gratis** y se consigue en unos 30 minutos.
Lo que realmente bloquea son dos cosas administrativas:

### Bloqueo 1 — Un número que no esté ya en WhatsApp

Cloud API exige un número de teléfono **sin cuenta de WhatsApp activa**. Si el
número que MERCAMIO quiere usar ya tiene WhatsApp —normal o la app Business—
hay que **eliminar esa cuenta** antes de registrarlo.

Y lo que se pierde no es solo el historial: **un número en Cloud API deja de
poder usarse en la app de WhatsApp**. Nadie podrá abrir WhatsApp con él ni
responder a mano desde un celular mientras esté en la API.

Así que la pregunta no es si tiene chats, sino si **alguien de contabilidad
atiende proveedores desde ese número hoy**. Si la respuesta es sí, al día
siguiente del registro no podrá. Esa decisión no es técnica.

Hay tres comprobaciones más —que reciba SMS, que no sea virtual, que no esté
ya en un BSP— en
[09 — Token y número de WhatsApp](09-registrar-numero-whatsapp.md).

Alternativas:
- Conseguir una línea nueva dedicada al bot.
- Usar el **número de prueba de Meta** (gratis, no necesita línea propia).

### Bloqueo 2 — Verificación de negocio, solo para producción

Para salir de las restricciones de prueba, Meta exige **Business Verification**
de MERCAMIO: NIT, certificado de cámara de comercio, comprobante de domicilio y
un dominio verificado. Tarda entre días y semanas, y depende de que alguien con
acceso a los documentos legales lo tramite.

---

## Qué SÍ se consigue hoy, gratis

| | Número de prueba de Meta | Número propio verificado |
|---|---|---|
| Cuesta | 0 | 0 (la línea, aparte) |
| Tiempo | ~30 min | días/semanas |
| Business Verification | **No** | Sí |
| Token permanente | Sí (System User) | Sí |
| A quién puede escribir | **5 números** que registres a mano | Cualquiera que le escriba |
| Conversaciones gratis/mes | 1.000 | 1.000 |
| Nombre visible | El de la app | El aprobado por Meta |

**El número de prueba alcanza de sobra para validar el bot con el equipo de
contabilidad.** 5 destinatarios registrados a mano es exactamente lo que se
necesita para un piloto interno.

Paso a paso completo, con el diagnóstico para no avanzar a ciegas:
[09 — Token y número de WhatsApp](09-registrar-numero-whatsapp.md).

Sigue haciendo falta el **túnel** para que Meta alcance tu n8n local
([03](03-webhook-whatsapp-tunel.md)).

---

## Pero WhatsApp no es el camino crítico

Esto es lo importante, y es incómodo: el transporte es el problema fácil. Está
resuelto en el repositorio y solo espera credenciales.

Lo que **nadie ha validado** es si las 9 rutas corresponden a cómo trabaja
contabilidad de verdad. Ninguna persona del área ha usado el bot. Y revisando
el flujo hay cuatro huecos de negocio que van a hundir el piloto antes de que
un token faltante importe:

### 1. `CLI_RET` pide solo el correo

La ruta de **devolución de retenciones** captura únicamente el correo
electrónico. Con eso, contabilidad recibe un ticket que dice, en esencia:
*"alguien quiere una devolución de retenciones, escríbele a este correo"*.

No hay NIT ni cédula, ni número de factura, ni período gravable, ni valor. El
ticket llega **inaccionable**: el primer paso de quien lo atiende es escribir
para pedir los datos que el bot no pidió, lo cual anula el motivo de tener bot.

Decisión pendiente: **¿qué necesita contabilidad como mínimo para localizar una
retención?** Casi con seguridad al menos identificación y período.

### 2. `CLI_CAR` no tiene responsable

El responsable configurado es literalmente *"Responsable de cartera por
confirmar"*. La ruta se marca como `ESCALAR`, pero escalar **a nadie** no es
escalar: el ticket se queda en la hoja sin dueño.

### 3. Tres de siete rutas prometen un SLA que no existe

`CLI_RET`, `PRO_CER`, `ACR_CER` (y `CLI_CAR`, `ACR_PEN`) responden *"Tiempo
estimado: Por confirmar"*. Un proveedor que lee eso entiende que nadie sabe
cuándo le van a responder — es peor que no decir nada.

### 4. No se puede consultar un ticket

El proveedor recibe `MCM-10129744` y **nunca más** puede preguntar por él. El
bot no sabe leer tickets. Lo que va a pasar en la práctica: vuelve a escribir,
el bot lo trata como caso nuevo y se genera un duplicado. Contabilidad termina
con la hoja llena de repetidos del mismo caso.

**Ninguno de los cuatro se arregla con un token.** Los cuatro se descubren
poniendo a contabilidad a usar el bot.

---

## El orden que tiene sentido

### Paso 1 — Validar el flujo con contabilidad (hoy, sin Meta)

```
http://localhost:5678/webhook/mercamio-chat
```

El chat web está servido por n8n. No necesita cuenta de Meta, ni credenciales
de Google, ni túnel. Muestra la conversación como WhatsApp y trae un panel con
la ruta y el ticket generado, así que sirve tanto para que un proveedor de
prueba converse como para que tú veas qué se registró.

Desde el móvil, en la misma red del PC:

```powershell
(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }).IPAddress
# luego en el movil:  http://<esa-ip>:5678/webhook/mercamio-chat
```

Qué pedirle al equipo, concretamente:

- Que **cada persona recorra la ruta que atiende** y diga si el ticket
  resultante le sirve para trabajar sin volver a preguntar nada.
- Que **complete los responsables y los SLA** de las 5 rutas que están "por
  confirmar". Eso va a `MERCAMIO_ROUTES_JSON` en `.env`.
- Que diga **qué datos faltan** en cada ruta. Añadirlos es editar
  `required: [...]` en `src/nodes/01-motor-conversacional.js` y un campo en
  `fieldLabels`.

Esto es media hora de reunión y es lo que decide si el proyecto sirve.

### Paso 2 — Google Sheets (30 min, gratis, sin Meta)

Independiente de WhatsApp. Con esto los tickets ya quedan registrados de verdad
y se puede evaluar si la hoja es un buen destino o si hace falta otra cosa.
Ver [04](04-credenciales.md).

### Paso 3 — Los dos trámites administrativos, en paralelo

No dependen de nadie técnico, así que conviene arrancarlos ya:

- **Decidir el número.** ¿Línea nueva para el bot, o se libera una existente?
- **Iniciar Business Verification.** Reunir NIT, cámara de comercio,
  comprobante de domicilio y verificar el dominio `mercamio.com.co`.

### Paso 4 — Número de prueba + túnel (cuando el flujo esté validado)

Token permanente gratis, 5 destinatarios registrados a mano, túnel de
Cloudflare. Sirve para probar el transporte real: entrega de Meta, acuses de
estado, la ventana de 24 horas. Ver [03](03-webhook-whatsapp-tunel.md) y
[04](04-credenciales.md).

### Paso 5 — Producción

Cuando la verificación esté aprobada y el número decidido.

---

## Si WhatsApp acaba siendo inviable

Escenarios reales en los que esto pasa: no hay línea disponible, la
verificación se atasca, o TI no autoriza exponer n8n a internet.

El motor conversacional es **independiente del canal**: recibe un texto y un
identificador de conversación, y devuelve un texto. Cambiar de canal es cambiar
el trigger, no el bot.

| Alternativa | Qué implica |
|---|---|
| **Chat en el portal de proveedores** | El chat de `src/ui/chat.html` ya funciona; habría que embeberlo en `mercamio.com.co/proveedores/` y apuntarlo a un n8n alcanzable. Ventaja: nada de Meta, nada de verificación, y el proveedor ya está en el portal. |
| **Telegram** | Token gratis en 2 minutos con `@BotFather`, sin verificación de negocio. Sigue necesitando túnel para el webhook. Contra: los proveedores colombianos no usan Telegram. |
| **Formulario web + correo** | No es conversacional, pero captura los mismos datos con la misma validación por ruta. Es lo más barato de operar. |

La del portal es la que más sentido tiene: el bot remite al portal de
proveedores en dos de sus rutas, así que el proveedor ya está ahí.

---

## Resumen

- El token es gratis y rápido. **No es el bloqueo.**
- Los bloqueos reales son el número de teléfono y la verificación de negocio,
  y son administrativos.
- Con el número de prueba se valida todo el transporte sin verificación.
- **Pero lo que hay que hacer primero es poner a contabilidad a usar el bot en
  el chat web y cerrar los cuatro huecos de negocio.** Eso no necesita Meta y
  es lo que decide si el proyecto sirve.
