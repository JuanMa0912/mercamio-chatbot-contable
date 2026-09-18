# MERCAMIO — ChatBOT contable

Chatbot de atención contable sobre **n8n autoalojado en Docker**. Atiende
clientes, proveedores de mercancías y acreedores de servicios por WhatsApp
Business, clasifica la solicitud en una de 9 rutas, recoge los datos que cada
ruta necesita y registra un ticket trazable en Google Sheets.

Este repositorio contiene la versión **V07**, que corrige 12 fallos de la V06 —
cuatro de ellos impedían que el bot respondiera. El análisis completo está en
[docs/05-auditoria-workflow.md](docs/05-auditoria-workflow.md).

---

## Arranque rápido

Lo mínimo para verlo funcionando. **No necesitas cuenta de Meta ni credenciales
de Google** para este camino.

```powershell
# 1. Configuración
Copy-Item .env.example .env
#    Edita .env: POSTGRES_PASSWORD y N8N_ENCRYPTION_KEY son obligatorios.
#    Genera la clave:  node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"

# 2. Levantar la pila (n8n + PostgreSQL)
docker compose up -d

# 3. Crear la cuenta de administrador
#    Abre http://localhost:5678 y completa el formulario de la primera vez.

# 4. Importar los workflows
powershell -File scripts/importar-workflows.ps1

# 5. En la interfaz: abre "V07 (Simulador local)" y ACTÍVALO con el interruptor

# 6. Conversar con el bot
#    Chat web (para que lo pruebe contabilidad):
#      http://localhost:5678/webhook/mercamio-chat
#    O por consola:
powershell -File scripts/simular-conversacion.ps1 -Guion acreedor-diferencia
```

Salida esperada del último paso:

```
tu  > hola
bot > Hola, soy el asistente contable de MERCAMIO. [...] Aceptas el tratamiento de datos?
      [accion=RESPUESTA estado=consentimiento ruta=]
...
tu  > 3250000
bot > Solicitud registrada con el ticket MCM-02632806. Categoria: Diferencia en
      valor pagado. Tiempo estimado: 3 dias.
      [accion=TICKET estado=finalizado ruta=ACR_DIF]
```

Si el bot repite el saludo en cada mensaje, el workflow **no está activo**. Es
el error más común: ver [docs/06-pruebas.md](docs/06-pruebas.md).

---

## Antes de seguir: dos límites que conviene tener claros

**1. El trigger de WhatsApp no funciona solo en local, y el token no es el
único requisito.** La API de Meta entrega los mensajes por webhook y necesita
una **URL pública HTTPS**; `localhost:5678` no le sirve. Además hacen falta un
número que no esté ya registrado en WhatsApp y, para producción, la
verificación de negocio de MERCAMIO. Ver
[docs/08-sin-token-de-meta.md](docs/08-sin-token-de-meta.md).

Por eso el repositorio incluye dos workflows: el **simulador** —con chat web
incluido— desarrolla y valida toda la lógica sin Meta, y el de **WhatsApp** se
conecta cuando haya túnel y credenciales.

**2. El estado de la conversación vive en el static data del workflow.** Sirve
para una instancia única —el escenario de este repositorio— pero no escala a
modo *queue* con varios workers. El umbral y la vía de migración a Redis están
en [docs/05-auditoria-workflow.md](docs/05-auditoria-workflow.md#deuda-técnica-pendiente).

---

## Documentación

| Guía | Contenido |
|------|-----------|
| [01 — Instalar Docker](docs/01-instalacion-docker.md) | Docker Desktop en Windows, WSL2, verificación. |
| [02 — n8n en local paso a paso](docs/02-n8n-local-paso-a-paso.md) | Levantar la pila, primer arranque, importar, activar, operar. |
| [03 — Webhook y túnel](docs/03-webhook-whatsapp-tunel.md) | Publicar n8n con Cloudflare Tunnel y registrar el webhook en Meta. |
| [04 — Credenciales](docs/04-credenciales.md) | WhatsApp Business API y Google Sheets OAuth2, con los detalles que suelen fallar. |
| [05 — Auditoría del workflow](docs/05-auditoria-workflow.md) | Los 12 fallos de la V06, por qué rompían y cómo se corrigieron. |
| [06 — Pruebas](docs/06-pruebas.md) | Pruebas del motor, simulador y diagnóstico de fallos. |
| [07 — Privacidad y repo público](docs/07-privacidad-y-repo-publico.md) | Qué NO puede subirse y cómo está resuelto. |
| [08 — Sin token de Meta](docs/08-sin-token-de-meta.md) | Qué se puede validar hoy, qué bloquea de verdad y en qué orden desbloquearlo. |
| [09 — Token y número de WhatsApp](docs/09-registrar-numero-whatsapp.md) | Conseguir el token permanente, registrar un número y comprobarlo antes de tocar n8n. |
| [10 — Qué cuesta de verdad](docs/10-costos-reales.md) | Qué es gratis, qué no, y el costo de disponibilidad que no aparece en ninguna factura. |

---

## Cómo está organizado

```
.
├── docker-compose.yml          Pila: n8n + PostgreSQL (+ túnel y Adminer opcionales)
├── .env.example                Plantilla de configuración  →  copiar a .env
│
├── src/
│   ├── nodes/                  ── FUENTE DE VERDAD DEL CÓDIGO ──
│   │   ├── 01-motor-conversacional.js  Máquina de estados de las 9 rutas
│   │   └── 02-recuperar-respuesta.js   Recupera el item tras escribir en Sheets
│   └── ui/chat.html            Chat web de pruebas, servido por n8n
│
├── scripts/
│   ├── build-workflow.mjs            Genera los JSON inyectando src/nodes/*.js
│   ├── importar-workflows.ps1        Prueba + genera + importa en n8n
│   ├── simular-conversacion.ps1      Conversa con el bot sin WhatsApp
│   └── verificar-whatsapp.ps1        Diagnostica el token y los números en Meta
│
├── tests/
│   ├── harness.mjs                   Ejecuta el motor con los globales de n8n simulados
│   └── motor.test.mjs                33 pruebas: 9 rutas + 12 regresiones
│
├── workflows/                  ── ARTEFACTOS GENERADOS, no editar a mano ──
│   ├── ...-v07-whatsapp.json         Producción
│   ├── ...-v07-simulador.json        Pruebas locales
│   └── historico/V06-...-sanitizado.json   Referencia de la auditoría
│
├── sheets/plantilla-solicitudes.csv  Encabezados de la hoja "Solicitudes"
└── docs/                             Las siete guías
```

### El código no se edita en la interfaz de n8n

Los `workflows/*.json` son **artefactos generados**. El código real vive en
`src/nodes/*.js` y se inyecta en el JSON al construir.

```
src/nodes/01-motor-conversacional.js
        │
        ├──> tests/harness.mjs ──> node --test    (pruebas sin n8n ni Docker)
        │
        └──> scripts/build-workflow.mjs ──> workflows/*.json ──> n8n
```

Un cambio hecho en el editor de n8n se **pierde** en el siguiente
`importar-workflows.ps1`. El ciclo correcto es:

```powershell
# 1. Editar src/nodes/01-motor-conversacional.js
# 2. Probar (rápido, sin Docker)
npm test
# 3. Generar e importar
powershell -File scripts/importar-workflows.ps1
# 4. Recargar la página de n8n (F5)
```

Se hizo así porque un nodo Code de 380 líneas dentro de un JSON no se puede
revisar, ni versionar con un diff legible, ni probar. Ahora una conversación
completa se valida en 90 ms.

---

## El flujo

```
                       ┌──────────────────────────┐
                       │ WhatsApp Business Trigger│   (o Webhook en el simulador)
                       └────────────┬─────────────┘
                                    │  evento crudo de Meta
                       ┌────────────▼─────────────┐
                       │ Motor conversacional     │  · descarta acuses de estado
                       │ 9 rutas                  │  · descarta webhooks repetidos
                       └────────────┬─────────────┘  · avanza la máquina de estados
                                    │
                       ┌────────────▼─────────────┐
                       │ ¿Tiene ticket?           │  evalúa has_ticket (booleano)
                       └──────┬────────────┬──────┘
                       TRUE   │            │   FALSE
                ┌─────────────▼──┐         │
                │ Sheets: append │         │
                └─────────┬──────┘         │
                ┌─────────▼──────┐         │
                │ Recuperar item │         │
                └─────────┬──────┘         │
                          └────────┬───────┘
                       ┌───────────▼──────────┐
                       │ Responder por WhatsApp│
                       └───────────────────────┘
```

Solo una de las dos ramas se ejecuta por mensaje. En la V06 ambas convergían
desde la **misma** rama y el usuario recibía la respuesta duplicada.

### Las 9 rutas

| Código | Perfil | Categoría | Datos que pide | SLA |
|--------|--------|-----------|----------------|-----|
| `CLI_RET` | Cliente | Devolución de retenciones | correo | Por confirmar |
| `CLI_CAR` | Cliente | Consulta de cartera | identificación, correo | Por confirmar ⚠️ escala |
| `PRO_PEN` | Proveedor | Factura pendiente (ya radicada) | identificación, n.º factura, comprobante | 2 días |
| `PRO_CER` | Proveedor | Certificados | identificación, tipo de certificado | Por confirmar |
| `ACR_DIF` | Acreedor | Diferencia en valor pagado | identificación, n.º factura, valor pagado | 3 días |
| `ACR_PEN` | Acreedor | Factura pendiente | identificación, n.º factura, persona contratante | Por confirmar ⚠️ escala |
| `ACR_CER` | Acreedor | Certificados | identificación, tipo de certificado | Por confirmar |
| — | Proveedor / Acreedor | Pago cancelado | — | remite al portal |
| — | Proveedor | Factura sin radicar | — | remite al portal |

Las dos últimas cierran la conversación sin generar ticket. Los responsables y
SLA reales se definen en `MERCAMIO_ROUTES_JSON` dentro de `.env`, **no en el
código**.

### Palabras de control

| El usuario escribe | Efecto |
|--------------------|--------|
| `REINICIAR` o `NUEVO` | Empieza de cero desde el consentimiento. |
| `1` / `si` / `sí` / `acepto` | Afirmativo. |
| `2` / `no` / `rechazo` | Negativo. |

Los menús aceptan tanto el número como la palabra (`2` o `proveedor`), sin
distinguir tildes ni mayúsculas.

---

## Operación diaria

```powershell
docker compose up -d                   # arrancar
docker compose ps                      # estado (ambos deben decir healthy)
docker compose logs -f n8n             # logs en vivo
docker compose down                    # parar, CONSERVANDO los datos
docker compose restart n8n             # recargar tras cambiar .env

npm test                               # pruebas del motor (sin Docker)
npm run build                          # regenerar los JSON
powershell -File scripts/importar-workflows.ps1
powershell -File scripts/simular-conversacion.ps1 -Guion interactivo
powershell -File scripts/verificar-whatsapp.ps1     # diagnóstico de Meta

docker compose --profile tools up -d   # Adminer en http://localhost:8080
docker compose --profile tunnel up -d  # túnel de Cloudflare
```

> `docker compose down -v` **borra los volúmenes**: se pierden los workflows,
> las credenciales y el historial. Solo para empezar de cero a propósito.

### Copia de seguridad

Lo irrecuperable son las **credenciales** (tokens de WhatsApp y Google, cifrados
con `N8N_ENCRYPTION_KEY`). Todo lo demás se reconstruye desde el repositorio.

```powershell
docker compose exec n8n n8n export:credentials --all --decrypted --output=/tmp/cred.json
docker compose cp n8n:/tmp/cred.json ./backup-credenciales.json
docker compose exec n8n rm /tmp/cred.json
```

`--decrypted` deja los tokens **en texto plano**. Ese archivo es tan sensible
como una contraseña: guárdalo cifrado y fuera del repositorio (`.gitignore` ya
bloquea `*credenciales*.json`, pero no dependas solo de eso).

---

## La cuenta de n8n

En el primer arranque, <http://localhost:5678> pide crear la cuenta de
propietario. Es una cuenta **local de esta instancia**: no es una cuenta de
n8n.cloud, y el correo que pongas es solo un identificador — **no conecta con
Google**. La credencial de Google Sheets es OAuth aparte
([04](docs/04-credenciales.md)).

> **La contraseña merece una fuerte de verdad.** El `docker-compose.yml`
> incluye el perfil `tunnel`, necesario para WhatsApp. En cuanto se activa,
> ese login queda expuesto a internet, y detrás de él están el token de
> WhatsApp y el OAuth de Google con acceso a la hoja de solicitudes. Quien
> entre no solo lee: puede editar el workflow y redirigir los tickets.
>
> Usa 20 caracteres aleatorios del gestor de contraseñas. Evita cualquier cosa
> derivada de `mercamio`: está en cualquier lista construida a partir del
> dominio.

En autoalojado **no hay recuperación por correo**. Si se pierde la contraseña,
la única salida borra la cuenta:

```powershell
docker compose exec n8n n8n user-management:reset
```

Los workflows y las credenciales sobreviven a ese reset; hay que volver a
crear la cuenta de propietario.

---

## Configuración

Todo está en `.env`, que **no se versiona**. Ver
[.env.example](.env.example) para la lista completa.

Las obligatorias:

| Variable | Para qué |
|----------|----------|
| `POSTGRES_PASSWORD` | Contraseña de la base de datos. |
| `N8N_ENCRYPTION_KEY` | Cifra las credenciales. **Si la pierdes, hay que reconectar WhatsApp y Google a mano.** Guárdala en el gestor de contraseñas. |

Las del chatbot:

| Variable | Para qué |
|----------|----------|
| `MERCAMIO_SHEET_ID` | ID de la hoja de solicitudes (el tramo entre `/d/` y `/edit`). |
| `MERCAMIO_ROUTES_JSON` | Responsable y SLA de cada ruta, en una línea. Aquí viven los correos internos. |
| `MERCAMIO_PORTAL_URL` | Portal de proveedores al que se remite en las rutas de cierre. |
| `MERCAMIO_SESSION_TTL_MIN` | Minutos de inactividad antes de descartar una conversación a medias. Por defecto 60. |
| `MERCAMIO_MAX_SESSIONS` | Tope de conversaciones en memoria. Por defecto 500. |
| `WEBHOOK_URL` | URL pública que n8n informa a Meta y Google. Debe coincidir con la real. |

Tras cambiar `.env`: `docker compose up -d` (recrea el contenedor con los
valores nuevos; `restart` **no** relee el archivo).

---

## Qué se versiona y qué no

`.gitignore` excluye, a propósito:

- **`.claude/`, `CLAUDE.md`, `.mcp.json`** — configuración de Claude Code, local.
- **`.env`** — secretos y correos internos. La plantilla `.env.example` sí se versiona.
- **`workflows/historico/V06-original-CON-DATOS-REALES.json`** — el JSON original
  lleva 5 correos de empleados, el ID de la hoja y 3 IDs de credenciales. En el
  repositorio va la versión sanitizada.
- **`*credenciales*.json`, `n8n-credentials*.json`** — exportaciones con tokens en claro.

Antes de hacer público el repositorio, lee
[docs/07-privacidad-y-repo-publico.md](docs/07-privacidad-y-repo-publico.md).

---

## Licencia

Propiedad de MERCAMIO S.A.S. — todos los derechos reservados. El repositorio es
publico para consulta y documentacion, pero **no concede licencia de uso,
copia, modificacion ni redistribucion**. Ver [LICENSE](LICENSE).

Si alguna vez se quiere permitir la reutilizacion del patron (n8n + maquina de
estados testeable + build reproducible), lo limpio es extraerlo a un
repositorio aparte con licencia permisiva y sin las rutas de negocio.

---

## Requisitos

| | |
|---|---|
| Docker Desktop | 4.x con WSL2 — [guía](docs/01-instalacion-docker.md). **Solo gratis si la empresa tiene <250 empleados y <10 M USD**; si no, requiere licencia o migrar a Docker Engine en WSL2 ([10](docs/10-costos-reales.md)). |
| Node.js | ≥ 20, solo para las pruebas y el build (no para ejecutar el bot) |
| n8n | 1.117.2, fijada en `.env`. `latest` rompe flujos sin avisar. |
| RAM libre | ~2 GB |
| Puertos | 5678 (n8n), 8080 (Adminer, opcional) |

---

## Estado

- ✅ Motor de 9 rutas, 33 pruebas en verde
- ✅ Simulador local funcionando de punta a punta en Docker
- ✅ Estado de conversación con TTL, tope e idempotencia
- ✅ Los 12 fallos de la V06 corregidos y con prueba de regresión
- ✅ Chat web de pruebas servido por n8n, sin cuentas externas
- ⏳ WhatsApp Business: requiere túnel + credenciales ([03](docs/03-webhook-whatsapp-tunel.md), [04](docs/04-credenciales.md), [08](docs/08-sin-token-de-meta.md))
- ⏳ Google Sheets: requiere credencial OAuth2 ([04](docs/04-credenciales.md))
- ❌ Consulta del estado de un ticket ya creado — no implementado
- ❌ Notificaciones de seguimiento — requieren plantillas aprobadas por Meta
