# 04 — Credenciales: WhatsApp Business y Google Sheets

El workflow de producción necesita tres credenciales. Las credenciales **no se
versionan**: se crean una vez en la interfaz de n8n y quedan cifradas en la
base de datos con `N8N_ENCRYPTION_KEY`.

| Credencial | Nodo | Para qué |
|---|---|---|
| WhatsApp Trigger API | WhatsApp Business Trigger | Recibir los mensajes. |
| WhatsApp API | Responder por WhatsApp Business | Enviar las respuestas. |
| Google Sheets OAuth2 | Registrar solicitud en Sheets | Escribir los tickets. |

Son dos credenciales distintas para WhatsApp y **no llevan los mismos datos**:
la de envío usa el access token; la del trigger usa el App ID y el App Secret.
Detalle en [4. En n8n](#4-en-n8n).

---

## Google Sheets — hazlo primero

Es la más rápida y no depende de Meta. Con esto ya puedes validar el registro de
tickets.

### 1. Preparar la hoja

Crea una hoja de cálculo con una pestaña llamada **exactamente** `Solicitudes`
(el nodo la busca por nombre; `Hoja 1` o `Sheet1` no funcionan).

Los encabezados, en la fila 1 y en este orden, están en
[`sheets/plantilla-solicitudes.csv`](../sheets/plantilla-solicitudes.csv):

```
ticket_id, fecha_creacion, session_id, estado, tipo_usuario, categoria, ruta,
nombre, identificacion, numero_factura, comprobante, correo, tipo_certificado,
valor_pagado, persona_contratante, responsable, sla, observaciones
```

Puedes importar el CSV directamente: **Archivo → Importar → Reemplazar hoja
actual**, y renombrar la pestaña a `Solicitudes`.

> El nodo mapea por **nombre de columna**, no por posición: puedes reordenarlas,
> pero no renombrarlas. Una columna con el nombre cambiado se queda vacía sin
> ningún error.

Copia el ID de la hoja de la URL — el tramo entre `/d/` y `/edit`:

```
https://docs.google.com/spreadsheets/d/ESTE_ES_EL_ID/edit
```

En `.env`:

```ini
MERCAMIO_SHEET_ID=ESTE_ES_EL_ID
```

```powershell
docker compose up -d      # NO 'restart': no relee .env
```

El nodo lee este valor con `{{ $env.MERCAMIO_SHEET_ID }}`, así que el ID de un
documento interno de MERCAMIO no queda escrito en el repositorio.

### 2. Proyecto en Google Cloud

1. <https://console.cloud.google.com> → crea un proyecto (`mercamio-chatbot`).
2. **APIs y servicios → Biblioteca** → habilita **Google Sheets API**.
   No hace falta Google Drive API: el nodo accede por ID, no navegando.
3. **Pantalla de consentimiento de OAuth**:
   - Tipo **Interno** si MERCAMIO usa Google Workspace. Evita la revisión de
     Google y el aviso de "app no verificada".
   - Si es **Externo**, añade tu correo en **Usuarios de prueba**. Sin eso,
     `Error 403: access_denied` al autorizar.
4. **Credenciales → Crear credenciales → ID de cliente de OAuth**:
   - Tipo: **Aplicación web**
   - **URI de redireccionamiento autorizado**:

     ```
     http://localhost:5678/rest/oauth2-credential/callback
     ```

     Con túnel, además:

     ```
     https://n8n-dev.mercamio.com.co/rest/oauth2-credential/callback
     ```

> **Google acepta `http` solo para `localhost`.** Es la excepción documentada de
> OAuth 2.0 para clientes locales. Para cualquier otro host exige `https`, y es
> el motivo por el que con túnel hay que poner `N8N_PROTOCOL=https`: si no, n8n
> genera la URL de callback en `http` y Google la rechaza con
> `redirect_uri_mismatch`.

Copia el **ID de cliente** y el **secreto**.

### 3. En n8n

**Credentials → Add credential → Google Sheets OAuth2 API**:

1. Pega Client ID y Client Secret.
2. **Sign in with Google** → autoriza.
3. **Save**.

Abre el workflow **V07 (WhatsApp)**, entra en **Registrar solicitud en Sheets**
y selecciona la credencial. Comprueba que `Sheet Name` diga `Solicitudes`.

### Si falla

| Error | Causa |
|---|---|
| `redirect_uri_mismatch` | La URI de redirección no coincide **exactamente**, incluido el protocolo y la barra final. |
| `Error 403: access_denied` | Pantalla de consentimiento externa sin tu correo en usuarios de prueba. |
| `The caller does not have permission` | La cuenta que autorizó no tiene acceso de edición a la hoja. |
| `Unable to parse range: Solicitudes!A:A` | La pestaña no se llama `Solicitudes`. |
| Se escribe la fila pero con columnas vacías | Un encabezado renombrado, o `MERCAMIO_SHEET_ID` apunta a otra hoja. |

---

## WhatsApp Business API

Más laborioso porque depende de la configuración de Meta.

### 1. Requisitos previos

- Cuenta de **Meta Business** verificada.
- Una app de tipo **Business** en <https://developers.facebook.com>.
- Producto **WhatsApp** añadido a la app.
- Un número de teléfono registrado (el de pruebas de Meta sirve para empezar).

### 2. Token permanente — no uses el temporal

En **WhatsApp → API Setup** hay un *temporary access token* que **caduca en 24
horas**. Sirve para la primera prueba y nada más: el bot dejará de responder al
día siguiente con un error de autenticación, y es un fallo que despista porque
el día anterior funcionaba.

Para un token permanente, vía **System User**:

1. <https://business.facebook.com/settings> → **Usuarios → Usuarios del sistema**
2. **Agregar** → nombre `chatbot-contable-n8n`, rol **Administrador**.
3. **Agregar activos** → tu app de WhatsApp → permiso **Administrar app**.
4. **Generar token nuevo** → selecciona la app → marca:
   - `whatsapp_business_messaging`
   - `whatsapp_business_management`
5. **Caducidad: Nunca**.
6. Copia el token. **Solo se muestra una vez.** Guárdalo en el gestor de
   contraseñas.

### 3. Datos que necesitas

De **WhatsApp → API Setup**:

| Dato | Dónde está |
|---|---|
| **Phone number ID** | Junto al número, en *From*. Es un número largo, no el teléfono. |
| **WhatsApp Business Account ID** | Arriba en la misma página. |
| **Access token** | El permanente del paso anterior. |

### 4. En n8n

Son **dos credenciales con campos distintos**, y aquí está la confusión más
común:

| Credencial | Nodo | Campos reales |
|---|---|---|
| `whatsAppApi` | Responder por WhatsApp Business | `accessToken` + `businessAccountId` |
| `whatsAppTriggerApi` | WhatsApp Business Trigger | `clientId` + `clientSecret` |

> **La credencial del trigger NO lleva el access token.** Lleva el **App ID** y
> el **App Secret** (Meta → **Configuración → Básica**). Los usa para dos cosas:
> autenticarse como la app para registrar el webhook en Meta, y validar la firma
> `X-Hub-Signature-256` de cada evento entrante.
>
> Si pones ahí el access token, la activación falla. Si el App Secret está mal
> copiado, **el bot no responde a nada y no hay ningún error visible**: todos
> los mensajes legítimos fallan la comprobación de firma y se descartan en
> silencio. Si Meta entrega y n8n no ejecuta nada, sospecha del App Secret
> antes que de cualquier otra cosa.

**La forma rápida** — lee los valores de `.env`, crea las dos con ID fijo, y el
workflow generado ya las referencia, así que no hay que asignarlas a mano ni
reasignarlas tras cada importación:

```powershell
powershell -File scripts/crear-credenciales-whatsapp.ps1
```

El token nunca pasa por la terminal: se lee de `.env`, se escribe a un temporal
fuera del repositorio, se importa cifrado y se borra de los dos lados.

**A mano**, si prefieres la interfaz: **Credentials → Add credential**, una de
cada tipo, y luego asignarlas en cada nodo. Si las creas así, sus IDs no
coincidirán con los que espera el JSON generado y tendrás que reasignarlas cada
vez que reimportes.

### 5. El `phoneNumberId` se resuelve solo

El nodo de envío usa:

```
phoneNumberId: {{ $json.businessPhoneNumberId }}
```

El motor lo extrae del propio evento entrante
(`value.metadata.phone_number_id`), así que el bot responde **desde el mismo
número** al que le escribieron, sin configurarlo. Si MERCAMIO añade un segundo
número, funciona sin tocar nada.

Como red de seguridad, si el evento no lo trae, el motor cae a la variable de
entorno `WHATSAPP_PHONE_NUMBER_ID`. Puedes definirla en `.env` si quieres un
valor fijo, pero no es necesaria.

### Si falla

| Error | Causa |
|---|---|
| `#190` Invalid OAuth access token | Token caducado. Es el temporal de 24 h. |
| `#131030` Recipient not in allowed list | Con el número de pruebas, hay que añadir el destinatario en la lista de Meta. |
| `#131047` Re-engagement message | Pasaron más de 24 h desde el último mensaje del usuario. Requiere plantilla aprobada. |
| `#131009` Parameter value is not valid | El cuerpo del mensaje llegó vacío. El motor V07 lo previene con su red de seguridad final. |
| `#133010` Phone number not registered | El número no está registrado en Cloud API. |
| Recibe pero no responde | Falta la credencial en el nodo de envío, o `waTo` llega vacío. |

---

## La ventana de 24 horas

Es una restricción de Meta, no del bot: **solo se puede enviar texto libre
dentro de las 24 horas siguientes al último mensaje del usuario.** Pasado ese
plazo hace falta una **plantilla aprobada**.

El flujo actual es puramente reactivo —responde a quien escribe— así que no le
afecta. Pero cualquier notificación de seguimiento ("tu ticket se resolvió")
**fallará** con `#131047`. Implementarlo requiere:

1. Crear y someter la plantilla a aprobación de Meta (24-48 h).
2. Un workflow aparte que use el nodo WhatsApp en modo `template`.

No está en este repositorio.

---

## Verificar

```powershell
# 1. Motor (no necesita ninguna credencial)
npm test

# 2. Simulador (no necesita credenciales)
powershell -File scripts/simular-conversacion.ps1 -Guion acreedor-diferencia

# 3. Sheets: habilita el nodo en el simulador y repite el paso 2.
#    Debe aparecer una fila nueva en la hoja.

# 4. WhatsApp: escribe al número desde un móvil.
```

Hazlo en ese orden. Si el paso 2 falla, el problema no está en las credenciales.

---

## Gestión de los secretos

Resumen de dónde vive cada cosa y qué pasa si se pierde:

| Secreto | Dónde | Si se pierde |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | `.env` | Todas las credenciales quedan ilegibles. Hay que reconectar todo. |
| Contraseña de la cuenta de n8n | Gestor de contraseñas | No hay recuperación por correo en autoalojado. |
| Token permanente de WhatsApp | n8n (cifrado) + gestor | Se genera otro desde el System User. |
| Client Secret de Google | n8n (cifrado) + gestor | Se genera otro en Google Cloud. |
| `MERCAMIO_ROUTES_JSON` | `.env` | Se reconstruye: son los correos de contabilidad. |

Ninguno de ellos está en el repositorio, y `.gitignore` bloquea `.env` y las
exportaciones de credenciales. Detalle en
[07 — Privacidad](07-privacidad-y-repo-publico.md).
