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

## Registrar el webhook en Meta

Con el túnel arriba y el workflow de WhatsApp importado:

### 1. La URL del webhook

Abre el workflow **V07 (WhatsApp)** en n8n, haz doble clic en **WhatsApp
Business Trigger** y copia la **Production URL**. Tendrá esta forma:

```
https://n8n-dev.mercamio.com.co/webhook/<id>/webhook
```

Si ahí sigue apareciendo `localhost`, `WEBHOOK_URL` no se aplicó: revisa que
usaste `docker compose up -d` y no `restart`.

### 2. Activar el workflow

El webhook **solo existe si el workflow está activo**. Con el workflow inactivo,
la URL devuelve 404 y la verificación de Meta falla.

### 3. En el panel de Meta

<https://developers.facebook.com> → tu app → **WhatsApp → Configuration** →
**Webhook → Edit**:

- **Callback URL**: la Production URL copiada.
- **Verify token**: cualquier cadena. n8n no la valida, pero Meta la exige.
- **Verify and save**.

Meta hace un `GET` con `hub.challenge` a esa URL. Si responde, queda verificado.

### 4. Suscribir el campo `messages`

En **Webhook fields**, marca **messages**. Es el único que hace falta.

> Ese campo entrega **dos** tipos de evento: mensajes entrantes
> (`value.messages[]`) y acuses de estado de los mensajes que **tú** enviaste
> (`value.statuses[]`: `sent`, `delivered`, `read`).
>
> Los acuses también disparan el workflow. Cada respuesta del bot genera al
> menos tres. El motor V07 los descarta al principio:
>
> ```js
> if (!message) { return []; }
> ```
>
> La V06 no lo hacía: los procesaba como mensajes vacíos, todos bajo la misma
> sesión `'demo-mercamio'`. Ver
> [05 — BUG-05](05-auditoria-workflow.md#bug-05--el-trigger-se-auto-dispara-con-los-callbacks-de-estado).

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

La ruta `/webhook/*` tiene que ser pública para que Meta entregue, y n8n **no
valida la firma** `X-Hub-Signature-256` de Meta en el nodo trigger. Consecuencia:
cualquiera que conozca la URL puede inyectar eventos falsos en tu flujo.

Mitigaciones, de menor a mayor esfuerzo:

1. **No compartas la URL del webhook.** Contiene un id aleatorio, así que no es
   adivinable — pero tampoco es un secreto criptográfico.
2. **Regla de WAF en Cloudflare** que solo admita `POST` desde los rangos de IP
   de Meta a `/webhook/*`. Es la opción con mejor relación esfuerzo/beneficio.
3. **Validar la firma HMAC** con un nodo Code antes del motor, usando el
   `App Secret` de la app de Meta. Es lo correcto, y no está implementado en
   este repositorio: requiere acceso al cuerpo crudo de la petición, que el
   nodo WhatsApp Trigger no expone (haría falta sustituirlo por un nodo Webhook
   genérico con `rawBody`).

Para un entorno de pruebas con túnel, la opción 2 es suficiente. Antes de
atender proveedores reales, la 3.

---

## Siguiente

[04 — Credenciales](04-credenciales.md)
