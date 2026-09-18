# 03 — Publicar el webhook para WhatsApp

## El problema, primero

WhatsApp Cloud API **no consulta** a tu servidor: le **entrega** los mensajes
por HTTP POST a una URL que tú registras en Meta. Esa URL tiene que ser:

- accesible desde internet,
- **HTTPS** con certificado válido,
- en el puerto 443.

`http://localhost:5678` no cumple ninguna de las tres. Los servidores de Meta
no tienen forma de alcanzar tu equipo.

Por eso "montarlo en local" y "conectar WhatsApp real" son dos cosas distintas:

| | Simulador local | WhatsApp real |
|---|---|---|
| Necesita internet entrante | No | **Sí** |
| Necesita cuenta de Meta | No | Sí |
| Prueba el motor de 9 rutas | Sí, completo | Sí |
| Prueba la entrega de Meta | No | Sí |

**Desarrolla con el simulador. Usa el túnel solo cuando necesites validar con el
número real.** Toda la lógica del bot —las 9 rutas, la recolección de datos, el
ticket— se valida sin Meta de por medio. El túnel solo añade el transporte.

---

## Opción A — Cloudflare Tunnel (recomendada)

Un túnel con nombre da una URL estable que no cambia al reiniciar. Es lo que
hace viable tener el webhook registrado en Meta sin reconfigurarlo cada día.

Requiere un dominio gestionado en Cloudflare. Si MERCAMIO ya tiene
`mercamio.com.co` ahí, sirve un subdominio como `n8n-dev.mercamio.com.co`.

### Crear el túnel

1. Entra en <https://one.dash.cloudflare.com> → **Networks → Tunnels**.
2. **Create a tunnel** → **Cloudflared** → nombre `mercamio-n8n-local`.
3. Copia el **token** que aparece (una cadena larga que empieza por `eyJ`).
4. En **Public Hostnames**, añade:
   - Subdomain: `n8n-dev`
   - Domain: `mercamio.com.co`
   - Service: **HTTP** → `n8n:5678`

   `n8n` es el nombre del servicio en `docker-compose.yml`: el contenedor
   `cloudflared` está en la misma red y resuelve ese nombre por DNS interno. No
   pongas `localhost` — dentro del contenedor de cloudflared, `localhost` es él
   mismo.

### Configurar y arrancar

En `.env`:

```ini
TUNNEL_TOKEN=eyJhIjoiXXXXXXXX...
WEBHOOK_URL=https://n8n-dev.mercamio.com.co/
N8N_HOST=n8n-dev.mercamio.com.co
N8N_PROTOCOL=https
N8N_SECURE_COOKIE=true
N8N_PROXY_HOPS=1
```

```powershell
docker compose --profile tunnel up -d
docker compose logs cloudflared --tail 20
```

Busca `Registered tunnel connection`. Comprueba:

```powershell
Invoke-RestMethod https://n8n-dev.mercamio.com.co/healthz
# status : ok
```

### Por qué cada variable

| Variable | Qué pasa si está mal |
|---|---|
| `WEBHOOK_URL` | n8n muestra la URL del webhook con este prefijo. Si sigue en `localhost`, copias una URL que Meta no puede alcanzar. |
| `N8N_PROTOCOL=https` | Los enlaces de callback de OAuth (Google) se generan en `http` y Google los rechaza. |
| `N8N_SECURE_COOKIE=true` | En HTTPS debe estar en `true`. Dejarlo en `false` manda la cookie de sesión sin protección. |
| `N8N_PROXY_HOPS=1` | Sin esto n8n ve la IP de cloudflared como IP del cliente. Afecta al limitador de peticiones y a los logs. |

> **Cierra el acceso.** Un túnel expone tu n8n a internet, incluido el
> formulario de login. Protégelo con **Cloudflare Access** (Zero Trust →
> Access → Applications) restringido a los correos de MERCAMIO, **excepto** la
> ruta `/webhook/*`, que debe quedar pública para que Meta entregue. Sin eso
> tienes un panel de automatización con tus credenciales de Google y WhatsApp
> expuesto a cualquiera que encuentre la URL.

---

## Opción B — Túnel rápido (solo pruebas de un rato)

Sin dominio, para una prueba puntual. **La URL cambia en cada arranque**, así
que hay que reconfigurar el webhook en Meta cada vez.

```powershell
docker run --rm --network mercamio-chatbot-contable_default `
  cloudflare/cloudflared:latest tunnel --url http://n8n:5678
```

Imprime algo como `https://random-words-1234.trycloudflare.com`. Ponlo en
`WEBHOOK_URL`, `docker compose up -d`, y úsalo mientras el comando siga
corriendo.

No sirve para nada permanente: en cuanto cierras la terminal, Meta empieza a
recibir errores de entrega.

---

## Opción C — ngrok

```powershell
ngrok http 5678
```

Con cuenta gratuita la URL también cambia en cada arranque. Con plan de pago
puedes fijar un dominio. Mismo tratamiento que la opción B: pon la URL en
`WEBHOOK_URL` y recrea el contenedor.

---

## El `--tunnel` propio de n8n: no lo uses

n8n trae un `--tunnel` integrado que enruta el tráfico por un servicio operado
por n8n. La propia documentación lo marca **solo para desarrollo**: el tráfico
—incluidos los mensajes de tus proveedores y sus datos de identificación— pasa
por un tercero. Para un flujo que trata datos personales bajo la Ley 1581 de
2012, no es una opción defendible.

---

## Registrar el webhook en Meta: n8n lo hace solo

**No vayas al panel de Meta a pegar la URL.** Es la parte contraintuitiva y
hacerlo a mano provoca un fallo.

Al activar el workflow, el nodo WhatsApp Trigger llama a la Graph API y crea la
suscripcion por su cuenta:

```js
// WhatsAppTrigger.node.js  ->  webhookMethods.default.create()
await appWebhookSubscriptionCreate(appId, {
  object: 'whatsapp_business_account',
  callback_url: webhookUrl,          // la URL del propio n8n
  verify_token: this.getNode().id,   // se lo inventa y lo valida el mismo
  fields: JSON.stringify(updates),   // ["messages"]
});
```

Por eso la credencial del trigger pide **App ID y App Secret** y no el access
token: los usa para autenticarse como la app y suscribirla.

### Que pasa si lo configuras a mano

Si ya hay una suscripcion en el panel con otra `callback_url`, la activacion
**falla**:

```
The WhatsApp App ID <id> already has a webhook subscription.
Delete it or use another App before executing the trigger.
Due to WhatsApp API limitations, you can have just one trigger per App.
```

Solucion: **borrar** la suscripcion manual en
**WhatsApp > Configuration > Webhook** y dejar que n8n la cree.

### Una app, un trigger

Limitacion de la API de Meta, no de n8n: **un solo WhatsApp Trigger por cada app
de Facebook**. Si necesitas dos flujos distintos, necesitas dos apps — o un
unico trigger que reparta por dentro.

### El orden correcto

```
1. Token, App ID y App Secret            -> Meta > API Setup y > Configuracion basica
2. Credenciales en n8n                   -> scripts/crear-credenciales-whatsapp.ps1
3. Tunel arriba (URL publica https)      -> scripts/tunel-rapido.ps1
4. Activar el workflow                   -> scripts/activar-whatsapp.ps1
     ^ aqui n8n registra el webhook en Meta, solo
5. Anadir destinatarios de prueba        -> Meta > API Setup > To
6. Escribir "hola" desde un celular
```

El paso 3 va **antes** del 4 a proposito: n8n registra en Meta la URL que tenga
configurada en ese momento. Si activas con `WEBHOOK_URL=http://localhost:5678`,
Meta se queda con una URL que no puede alcanzar, y hay que desactivar y volver
a activar.


---

## Verificar de punta a punta

1. Escribe "hola" desde un WhatsApp al número de la app.
2. En n8n, **Executions**: debe aparecer una ejecución nueva.
3. El bot responde con el mensaje de consentimiento.
4. Sigue la conversación. **`estado_sesion` debe avanzar** en cada mensaje.

### Si no llega nada

Diagnostica en este orden:

```powershell
# 1. ¿El túnel responde desde fuera?
Invoke-RestMethod https://n8n-dev.mercamio.com.co/healthz

# 2. ¿El workflow está activo?
docker compose exec -T postgres psql -U n8n -d n8n -t -A -c "select id, active from workflow_entity;"

# 3. ¿Llega alguna petición?
docker compose logs -f n8n
```

En el panel de Meta, **WhatsApp → Configuration → Webhook** muestra los errores
de entrega recientes. Si ahí no hay intentos, el problema está en Meta (webhook
mal registrado o campo sin suscribir), no en n8n.

| Error de Meta | Qué significa |
|---|---|
| `The URL couldn't be validated` | 404: el workflow está inactivo, o la URL está mal copiada. |
| `SSL handshake failed` | El túnel no está corriendo, o la URL es `http`. |
| Se verifica pero no llegan mensajes | Falta suscribir el campo `messages`. |
| `#131047` al responder | Pasaron más de 24 h desde el último mensaje del usuario. Requiere plantilla aprobada. |

---

## Seguridad del webhook

La ruta `/webhook/*` tiene que ser publica para que Meta entregue. La pregunta
es quien mas puede inyectar eventos.

**n8n valida la firma de Meta.** El nodo calcula el HMAC-SHA256 del cuerpo
crudo con el App Secret y lo compara con la cabecera `X-Hub-Signature-256`:

```js
// WhatsAppTrigger.node.js  ->  webhook()
const computedSignature = createHmac(sha256, credentials.clientSecret)
  .update(req.rawBody).digest(hex);
if (headerData['x-hub-signature-256'] !== `sha256=${computedSignature}`) {
  return {};   // descartado en silencio
}
if (bodyData.object !== 'whatsapp_business_account') return {};
```

Un evento falso sin la firma correcta se descarta antes de llegar al motor. Eso
solo funciona si el **App Secret de la credencial es el correcto**; si te
equivocas al copiarlo, el bot no responde a nada y no hay ningun error visible
—los mensajes legitimos tambien fallan la comprobacion de firma—. Es un modo de
fallo silencioso que cuesta diagnosticar: si Meta entrega y n8n no ejecuta nada,
sospecha del App Secret antes que de cualquier otra cosa.

Lo que **sigue** sin proteger es la interfaz de n8n, que el tunel tambien
expone. Ahi solo esta tu contrasena. Recomendable:

1. **Cloudflare Access** (Zero Trust > Access > Applications) limitado a los
   correos de MERCAMIO, **excepto** `/webhook/*`, que debe quedar publica.
2. Como minimo, una contrasena fuerte de verdad en la cuenta de n8n.


---

## Siguiente

[04 — Credenciales](04-credenciales.md)
