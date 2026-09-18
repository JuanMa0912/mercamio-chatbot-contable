# 09 — Token de Meta y registro del número de WhatsApp

Paso a paso para conseguir el token, registrar un número y comprobar que
funciona antes de tocar n8n.

---

## Antes de empezar: lo que se pierde al registrar un número

Esto es lo que más se subestima, y no tiene vuelta fácil.

> **Un número registrado en Cloud API deja de poder usarse en la app de
> WhatsApp.** No es que pierda el historial: pierde la capacidad de ser un
> teléfono. Nadie podrá abrir WhatsApp con ese número ni responder a mano desde
> un celular mientras esté en la API.

"No tiene chats" es una condición necesaria pero no suficiente. Las preguntas
que realmente hay que responder:

| Comprobación | Por qué importa | Si falla |
|---|---|---|
| ¿Alguien atiende proveedores desde ese número **hoy**? | Al día siguiente del registro no podrá. | Usar una línea distinta. |
| ¿Recibe **SMS o llamada de voz**? | El código de verificación llega por ahí. | Una línea que no recibe SMS necesita verificación por voz; una que no recibe ninguna de las dos no sirve. |
| ¿Es un número **virtual o VoIP**? | Meta rechaza la mayoría. | Usar una línea móvil o fija real. |
| ¿Está ya en un **BSP**? (Twilio, 360dialog, Gupshup, Wati) | Un número solo puede estar en un sitio. | Liberarlo o migrarlo desde ese proveedor primero. |
| ¿Es cuenta de **WhatsApp Business app**? | Se pierden también catálogo, etiquetas, mensajes de bienvenida y de ausencia. | Exportar lo que haga falta antes. |

**Recomendación:** haz primero todo el camino con el **número de prueba de
Meta** (gratis, no consume ninguna línea, token permanente, sin verificación de
negocio). Cuando el transporte esté validado, registra el número real. Así el
paso irreversible se da una sola vez y sabiendo que todo lo demás funciona.

---

## Paso 1 — Crear la app en Meta

1. Entra en <https://developers.facebook.com> con la cuenta de Facebook que
   administre el negocio.
2. **My Apps → Create App**.
3. Caso de uso: **Other** → tipo **Business**.
4. Nombre: `MERCAMIO ChatBOT contable`. Correo de contacto.
5. Si pide asociar una cuenta de Business Manager, selecciona la de MERCAMIO
   (o créala: es gratis e instantáneo).
6. Dentro de la app: **Add products → WhatsApp → Set up**.

Al terminar, Meta crea automáticamente:
- una **WhatsApp Business Account (WABA)** de prueba
- un **número de prueba** con su Phone Number ID
- un **token temporal de 24 horas**

---

## Paso 2 — Ver el token y los identificadores

**WhatsApp → API Setup** (en el menú izquierdo, bajo el producto WhatsApp).

Esa pantalla tiene todo lo que hace falta:

| Campo en pantalla | Qué es | Dónde se usa |
|---|---|---|
| **Temporary access token** | Token de 24 h | Solo para la primera prueba |
| **Phone number ID** | ID del número emisor | El bot lo resuelve solo del evento entrante; sirve para diagnóstico |
| **WhatsApp Business Account ID** | ID de la WABA | Credencial de n8n y script de diagnóstico |
| **From** | El número de prueba de Meta | — |
| **To** | Lista de destinatarios permitidos | Hay que registrar aquí los teléfonos de prueba |

> El token que aparece ahí **caduca en 24 horas**. Sirve para la primera
> prueba y nada más. Al día siguiente el bot deja de responder con un error de
> autenticación, y despista porque el día anterior funcionaba. El paso 3
> resuelve eso.

### Registrar los destinatarios de prueba

En **To → Manage phone number list**, añade los celulares con los que vas a
probar (hasta 5). Cada uno recibe un código de confirmación por WhatsApp.

Sin esto, cualquier envío falla con `#131030 Recipient phone number not in
allowed list`.

---

## Paso 3 — Token permanente (Usuario del sistema)

Gratis, instantáneo y **no requiere verificación de negocio**.

1. <https://business.facebook.com/settings>
2. **Usuarios → Usuarios del sistema → Agregar**
3. Nombre: `chatbot-contable-n8n`. Rol: **Administrador**.
4. **Agregar activos** — y aquí hay que añadir **dos** cosas, no una:
   - **Apps** → tu app → permiso **Administrar app** (control total)
   - **Cuentas de WhatsApp** → tu WABA → control total

   Si solo se añade la app, el token se genera pero no puede leer ni los
   números ni enviar mensajes. Es el error más común de este paso.
5. **Generar token nuevo** → selecciona la app → marca:
   - `whatsapp_business_messaging`
   - `whatsapp_business_management`
6. **Caducidad: Nunca**
7. Copia el token. **Solo se muestra una vez.** Guárdalo en el gestor de
   contraseñas.

---

## Paso 4 — Comprobar antes de seguir

No sigas a ciegas. Este repositorio trae un diagnóstico que consulta la Graph
API y te dice exactamente qué falta:

```powershell
# Pon el token en .env (esta en .gitignore):
#   WHATSAPP_TOKEN=EAAxxxxx...
#   WHATSAPP_WABA_ID=1234567890
#   WHATSAPP_PHONE_NUMBER_ID=0987654321

powershell -File scripts/verificar-whatsapp.ps1
```

Comprueba, en orden: validez del token, si es temporal o permanente, los dos
permisos, la WABA, y el estado de cada número (verificación, nombre visible,
calidad, plataforma). Termina con un veredicto.

Para cerrar la prueba con un envío real:

```powershell
powershell -File scripts/verificar-whatsapp.ps1 -EnviarA 573001112233
```

El destino tiene que estar en la lista de permitidos del paso 2.

### Lo que traduce el script

Meta explica el motivo real en el **cuerpo** de la respuesta, no en el código
HTTP. Sin eso, un token mal copiado y un permiso ausente dan exactamente el
mismo `401 No autorizado`. El script extrae el mensaje de Meta:

| Error | Qué significa |
|---|---|
| `#190 Malformed access token` | El token se copió incompleto o con espacios. |
| `#190 Session has expired` | Es el temporal de 24 h. Ver paso 3. |
| `#200` permisos insuficientes | Falta añadir la WABA como activo del Usuario del sistema (paso 4). |
| `#131030` | El destino no está en la lista de permitidos. |
| `#131026` | El destino no tiene WhatsApp, o el formato del número está mal. |
| `#133010` | El número no está registrado en Cloud API. |
| `#131047` | Pasaron 24 h desde el último mensaje del usuario: hace falta plantilla aprobada. |

Si el script dice que la versión de la Graph API no existe, súbela:
`-Version v24.0`. Meta retira versiones cada ~2 años.

---

## Paso 5 — Registrar el número propio

Solo cuando el número de prueba ya funcione de punta a punta con n8n.

### 5.1 Liberar el número

Si tiene cuenta de WhatsApp, hay que eliminarla **desde la app, con el número
en el teléfono**:

WhatsApp → **Ajustes → Cuenta → Eliminar mi cuenta**

Meta tarda un rato en liberarlo del todo. Si el registro falla justo después,
espera unas horas.

### 5.2 Añadirlo a la WABA

1. **WhatsApp → API Setup → Add phone number**
   (o **Business Settings → Cuentas de WhatsApp → tu WABA → Números de
   teléfono → Agregar**)
2. Datos del perfil:
   - **Nombre para mostrar**: lo revisa Meta. Debe parecerse al nombre real del
     negocio y a lo que hay en la web. `MERCAMIO` funciona; `Bot contable` casi
     seguro se rechaza.
   - **Categoría**, **descripción**, **zona horaria**
3. **Número de teléfono** en formato internacional (código de país + número).
4. **Método de verificación**: SMS o llamada.
5. Introduce el código de 6 dígitos.

### 5.3 Verificación en dos pasos (PIN)

Cloud API pide un **PIN de 6 dígitos** para el número. Guárdalo en el gestor:
hace falta para migrar el número o recuperarlo más adelante.

### 5.4 Estados posibles del nombre

| Estado | Qué implica |
|---|---|
| `APPROVED` | El proveedor ve `MERCAMIO`. |
| `PENDING_REVIEW` | El bot funciona igual, pero el proveedor ve el número crudo. |
| `DECLINED` | Hay que cambiar el nombre por uno que se parezca al negocio real. |

El `name_status` lo muestra `verificar-whatsapp.ps1`.

---

## Paso 6 — Verificación de negocio (solo producción)

No hace falta para probar. Sí para salir de los límites de prueba y para que
el nombre comercial quede aprobado.

**Business Settings → Centro de seguridad → Iniciar verificación.**

Documentos de MERCAMIO:
- NIT / RUT
- Certificado de cámara de comercio (reciente)
- Comprobante de domicilio a nombre de la empresa
- Un dominio verificado (`mercamio.com.co`) — se verifica con un registro DNS
  TXT o un meta-tag

Tarda entre días y semanas y no depende de nadie técnico. **Conviene arrancarlo
en paralelo**, no al final.

Los límites exactos de mensajería por nivel cambian; míralos en
**WhatsApp Manager → Información general** de tu propia cuenta en vez de
fiarte de un número escrito aquí. Lo estructural: el bot es **reactivo**
—responde a quien le escribe— así que los topes de conversaciones iniciadas por
el negocio le afectan poco.

---

## Paso 7 — Conectarlo con n8n

Con el diagnóstico en verde, son tres comandos:

```powershell
# 1. Crear las dos credenciales desde .env (ID fijo, ya referenciado)
powershell -File scripts/crear-credenciales-whatsapp.ps1

# 2. Publicar n8n en una URL https (sin cuenta de Cloudflare)
powershell -File scripts/tunel-rapido.ps1

# 3. Activar. Aqui n8n registra el webhook en Meta POR SI SOLO.
powershell -File scripts/activar-whatsapp.ps1
```

> ### No configures el webhook a mano en Meta
>
> Al activar, el nodo WhatsApp Trigger llama a la Graph API y crea la
> suscripción con su propia `callback_url` y su propio `verify_token`. **No hay
> que pegar nada en WhatsApp → Configuration → Webhook.**
>
> Si ya hay una suscripción manual, la activación falla con
> *"The WhatsApp App ID ... already has a webhook subscription"*. En ese caso
> hay que **borrar** la suscripción manual y dejar que n8n la cree.
>
> Detalle en [03](03-webhook-whatsapp-tunel.md#registrar-el-webhook-en-meta-n8n-lo-hace-solo).

El orden importa: el túnel va **antes** de activar, porque n8n registra en Meta
la URL que tenga en ese momento. Si activas con `WEBHOOK_URL` apuntando a
`localhost`, Meta se queda con una URL inalcanzable y hay que desactivar y
volver a activar.

Lo único que queda en el panel de Meta es añadir los destinatarios de prueba
(**API Setup → To → Manage phone number list**). Después, escribe "hola" desde
uno de ellos.

Lista de verificación completa en [06 — Pruebas](06-pruebas.md#nivel-3--whatsapp-real).

---

## Resumen del orden

```
1. App en Meta                          15 min   gratis
2. Ver token temporal e IDs               2 min   gratis
3. Token permanente (System User)       10 min   gratis, sin verificación
4. verificar-whatsapp.ps1                1 min   ← no sigas sin esto en verde
5. Túnel + credenciales + n8n            30 min
6. Probar con el número de PRUEBA        ---     ← aquí ya funciona el bot
---------------------------------------------------------------------------
7. Decidir la línea real                 ---     decisión de negocio
8. Registrar el número propio            20 min   PASO IRREVERSIBLE
9. Verificación de negocio            días/sem   en paralelo desde el día 1
```

Los pasos 1 a 6 no tocan ninguna línea de MERCAMIO y no tienen consecuencias.
El 8 sí.
