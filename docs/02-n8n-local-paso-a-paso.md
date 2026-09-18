# 02 — n8n en local, paso a paso

De un repositorio recién clonado a un bot conversando. Sin cuenta de Meta ni
credenciales de Google: eso viene en [03](03-webhook-whatsapp-tunel.md) y
[04](04-credenciales.md).

Tiempo: unos 15 minutos, casi todo descargando imágenes.

---

## Qué se levanta

```
┌─────────────────────────────────────────────────────────────┐
│  Red de Docker: mercamio-chatbot-contable_default           │
│                                                             │
│   ┌──────────────────┐         ┌──────────────────────┐     │
│   │ mercamio-n8n     │────────>│ mercamio-postgres    │     │
│   │ n8n 1.117.2      │  :5432  │ postgres:16-alpine   │     │
│   │ :5678            │         │ (sin puerto público) │     │
│   └────────┬─────────┘         └──────────┬───────────┘     │
│            │ vol: mercamio_n8n_data       │ vol:            │
│            │                              │ mercamio_       │
│            │                              │ postgres_data   │
└────────────┼──────────────────────────────┼─────────────────┘
             │ 0.0.0.0:5678
      http://localhost:5678
```

**PostgreSQL en vez de SQLite** a propósito. n8n usa SQLite por defecto, y con
un workflow que lee y escribe el static data en cada mensaje, SQLite bloquea el
archivo completo en cada escritura. Con varias conversaciones simultáneas
aparecen errores `SQLITE_BUSY` intermitentes, difíciles de diagnosticar porque
no fallan siempre.

PostgreSQL no publica ningún puerto al host: solo se alcanza desde la red de
compose. Una base de datos abierta en `localhost:5432` sin necesidad es
superficie de ataque gratis.

---

## Paso 1 — Configuración

```powershell
Copy-Item .env.example .env
```

Abre `.env` y rellena **las dos obligatorias**:

```ini
POSTGRES_PASSWORD=<algo largo y aleatorio>
N8N_ENCRYPTION_KEY=<64 caracteres hexadecimales>
```

Genera la clave de cifrado:

```powershell
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

> **`N8N_ENCRYPTION_KEY` merece un párrafo aparte.** Cifra los tokens de
> WhatsApp y Google guardados en la base de datos. Si la cambias o la pierdes,
> n8n arranca sin error pero **todas las credenciales quedan ilegibles** y hay
> que reconectar cada servicio a mano. Guárdala en el gestor de contraseñas
> antes de seguir. No es recuperable.

El compose **exige** ambas variables (sintaxis `${VAR:?...}`): si faltan, falla
al arrancar con un mensaje claro en vez de levantar algo roto.

### Lo que puedes dejar para después

`MERCAMIO_SHEET_ID`, `MERCAMIO_ROUTES_JSON` y `TUNNEL_TOKEN` solo hacen falta
para el camino de producción. Vacías, el motor usa sus valores por defecto
(`@pendiente.local`) y el simulador funciona igual.

---

## Paso 2 — Levantar

```powershell
docker compose up -d
```

La primera vez descarga ~1,3 GB. Después:

```powershell
docker compose ps
```

```
NAME                SERVICE     STATUS
mercamio-n8n        n8n         Up 2 minutes (healthy)
mercamio-postgres   postgres    Up 2 minutes (healthy)
```

Espera a que **ambos** digan `healthy`. n8n tarda unos 20-30 segundos en el
primer arranque porque ejecuta las migraciones de la base de datos.

Si `n8n` se queda en `starting` más de dos minutos:

```powershell
docker compose logs n8n --tail 50
```

Comprobación rápida:

```powershell
Invoke-RestMethod http://localhost:5678/healthz
# status : ok
```

---

## Paso 3 — Cuenta de administrador

Abre <http://localhost:5678>. La primera vez n8n pide crear la cuenta del
propietario: correo, nombre y contraseña.

Es una cuenta **local de esta instancia**, no una cuenta de n8n.cloud. Guárdala
en el gestor de contraseñas: sin ella no se puede entrar a la interfaz y no hay
recuperación por correo en una instalación autoalojada.

> Si el login entra en bucle y vuelve al formulario, es la cookie: en `http` n8n
> la marca como `Secure` y el navegador la descarta. `.env` ya trae
> `N8N_SECURE_COOKIE=false` para evitarlo. Si lo cambiaste, vuelve a ponerlo en
> `false` mientras trabajes en local.

---

## Paso 4 — Importar los workflows

```powershell
powershell -File scripts/importar-workflows.ps1
```

El script hace tres cosas en orden:

1. Ejecuta las 33 pruebas del motor. **Si fallan, no importa nada.**
2. Regenera `workflows/*.json` desde `src/nodes/*.js`.
3. Los importa con `n8n import:workflow`.

```
==> Ejecutando pruebas del motor conversacional
ℹ pass 33
ℹ fail 0
==> Generando los JSON de los workflows
generado  workflows/MERCAMIO-chatbot-contable-v07-whatsapp.json  (8 nodos)
generado  workflows/MERCAMIO-chatbot-contable-v07-simulador.json (7 nodos)
==> Importando los workflows en n8n
    Successfully imported 2 workflows.
```

Los workflows llevan **id fijo** (`mercamioWa000001`, `mercamioSim00001`), así
que reimportar **actualiza** los existentes. Sin id fijo, cada importación
dejaría un duplicado más — y con dos workflows activos escuchando el mismo
webhook, el usuario recibe cada respuesta dos veces.

### Manualmente, sin el script

Si prefieres la interfaz: **Workflows → ⋯ → Import from File** y selecciona el
JSON. O por CLI:

```powershell
docker compose exec n8n n8n import:workflow --separate --input=/workflows
```

En Git Bash hay que poner `MSYS_NO_PATHCONV=1` delante (ver [01](01-instalacion-docker.md)).

> En la salida aparece `Could not remove webhooks of workflow ... Could not find
> workflow`. Es ruido normal: n8n intenta desactivar el workflow antes de
> reemplazarlo y todavía no existe. El script lo filtra.

### La importación desactiva los workflows

`n8n import:workflow` sobrescribe **la fila completa**, incluida la columna
`active`, y los JSON generados llevan `active: false`. Consecuencia: cada
importación **desactiva** el bot.

Es una trampa desagradable porque no da ningún error: el webhook simplemente
empieza a devolver 404 y WhatsApp deja de responder sin que nada lo anuncie.

`importar-workflows.ps1` lo resuelve solo: anota qué workflows estaban activos
antes de importar, los reactiva después y reinicia n8n para volver a registrar
los webhooks. Si importas a mano —por CLI o desde la interfaz— tienes que
acordarte de reactivar.

---

## Paso 5 — Activar

Recarga <http://localhost:5678>. Verás dos workflows. Abre
**MERCAMIO - ChatBOT contable V07 (Simulador local)** y pulsa el interruptor
**Inactive → Active** arriba a la derecha.

> ### Esto no es opcional
>
> n8n **solo guarda** los cambios del static data en ejecuciones de
> **producción**. Con *Execute workflow* desde el editor, el estado de la
> conversación se descarta al terminar y el bot responde el saludo en **cada**
> mensaje.
>
> Es la causa más común de *"el bot no funciona"*: se prueba en el único modo en
> el que es imposible que funcione. Detalle en
> [05 — BUG-04](05-auditoria-workflow.md#bug-04--el-static-data-no-persiste-en-ejecuciones-de-prueba).

### Activar por CLI

```powershell
docker compose exec n8n n8n update:workflow --id=mercamioSim00001 --active=true
docker compose restart n8n
```

El `restart` es obligatorio: la CLI avisa de que *"Activation will not take
effect if n8n is running"*, porque el proceso en marcha no reregistra los
webhooks por su cuenta.

---

## Paso 6 — Conversar

```powershell
powershell -File scripts/simular-conversacion.ps1 -Guion acreedor-diferencia
```

```
tu  > hola
bot > Hola, soy el asistente contable de MERCAMIO. [...]
      [accion=RESPUESTA estado=consentimiento ruta=]

tu  > 1
bot > Gracias. Cual es tu nombre completo?
      [accion=RESPUESTA estado=nombre ruta=]
...
tu  > 3250000
bot > Solicitud registrada con el ticket MCM-02632806. [...]
      [accion=TICKET estado=finalizado ruta=ACR_DIF]
```

Lo que confirma que todo está bien es que **`estado` avanza** entre mensajes.
Si se queda en `consentimiento`, el workflow no está activo o estás llamando a
`/webhook-test/` en vez de `/webhook/`.

Guiones disponibles: `completo`, `cliente-retenciones`, `cliente-cartera`,
`proveedor-factura`, `proveedor-certificado`, `acreedor-diferencia`,
`acreedor-factura`, `acreedor-certificado`, `portal-proveedor`,
`rechaza-datos`, `interactivo`.

O a mano:

```powershell
Invoke-RestMethod -Uri http://localhost:5678/webhook/mercamio-sim -Method Post `
  -ContentType 'application/json' -Body '{"from":"573001112233","text":"hola"}'
```

---

## Operación

### Comandos

```powershell
docker compose up -d           # arrancar (o aplicar cambios de .env)
docker compose ps              # estado
docker compose logs -f n8n     # logs en vivo
docker compose restart n8n     # reiniciar el proceso
docker compose down            # parar, CONSERVANDO los datos
docker compose down -v         # parar y BORRAR workflows, credenciales, historial
```

**`restart` no relee `.env`.** Las variables de entorno se fijan al crear el
contenedor. Tras editar `.env` hay que usar `docker compose up -d`, que detecta
el cambio y recrea el contenedor.

### Perfiles opcionales

```powershell
docker compose --profile tools up -d     # Adminer  -> http://localhost:8080
docker compose --profile tunnel up -d    # túnel de Cloudflare
```

Adminer para inspeccionar la base de datos. Datos de conexión: servidor
`postgres`, usuario y contraseña los de `.env`, base `n8n`.

### Actualizar n8n

La versión está fijada a propósito:

```ini
N8N_VERSION=1.117.2
```

`latest` cambia cuando Docker vuelve a descargar la imagen, y un cambio de
`typeVersion` en un nodo puede romper el flujo sin ningún aviso. Para subir de
versión:

1. Exporta las credenciales (ver *Copia de seguridad* en el [README](../README.md)).
2. Cambia `N8N_VERSION`.
3. `docker compose up -d`
4. Vuelve a pasar el simulador por todas las rutas.

Baja una versión a la vez. n8n aplica migraciones de base de datos que **no son
reversibles**: volver atrás exige restaurar el volumen.

---

## Si algo no funciona

| Síntoma | Causa más probable |
|---|---|
| El bot repite el saludo siempre | El workflow no está activo, o se usa `/webhook-test/`. |
| `404` al llamar al webhook | El workflow no está activo. |
| Respuesta vacía con `200` | Correcto: el motor descartó el evento (repetido o acuse de estado). |
| `502`/`ECONNREFUSED` | n8n no está `healthy`. Mira `docker compose logs n8n`. |
| Mensaje duplicado en WhatsApp | Hay dos workflows activos con el mismo trigger. |
| Cambié el código y no pasa nada | Falta `importar-workflows.ps1` y recargar la página. |
| El login vuelve al formulario | `N8N_SECURE_COOKIE` debe ser `false` en `http`. |
| Faltan las credenciales tras recrear | Cambió `N8N_ENCRYPTION_KEY`. |

Diagnóstico detallado en [06 — Pruebas](06-pruebas.md).

---

## Siguiente

- [03 — Webhook y túnel](03-webhook-whatsapp-tunel.md) para conectar WhatsApp.
- [04 — Credenciales](04-credenciales.md) para WhatsApp y Google Sheets.
- [06 — Pruebas](06-pruebas.md) para validar y diagnosticar.
