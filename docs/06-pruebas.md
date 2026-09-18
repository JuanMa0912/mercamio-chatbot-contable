# 06 — Pruebas y diagnóstico

Tres niveles, del más rápido al más completo. Úsalos en orden: si el nivel 1
falla, no tiene sentido mirar Docker.

| Nivel | Qué prueba | Necesita | Tiempo |
|---|---|---|---|
| 1. Motor | Las 9 rutas y las 12 regresiones | Node ≥ 20 | ~90 ms |
| 2. Simulador | El flujo completo dentro de n8n | Docker | ~5 s |
| 3. WhatsApp | La entrega real de Meta | Túnel + credenciales | minutos |

---

## Nivel 1 — El motor, sin n8n

```powershell
npm test
```

```
▶ regresiones de la version V06
  ✔ BUG-01: has_ticket es siempre booleano y ticket siempre objeto
  ✔ BUG-05: los callbacks de estado de Meta se descartan
  ✔ BUG-06: un webhook reintentado por Meta no avanza la conversacion
  ...
▶ rutas que generan ticket
  ✔ CLI_RET - Cliente / devolucion de retenciones
  ✔ CLI_CAR - Cliente / consulta de cartera
  ...
ℹ pass 33
ℹ fail 0
```

### Cómo funciona

`tests/harness.mjs` lee el **mismo archivo** que se inyecta en el nodo Code y lo
ejecuta con los globales de n8n simulados:

```js
const CUERPO_MOTOR = readFileSync('src/nodes/01-motor-conversacional.js', 'utf8');
const ejecutarMotor = new Function('$input', '$getWorkflowStaticData', '$env', 'console', CUERPO_MOTOR);
```

`new Function` es lo que permite que el archivo tenga `return` en el nivel
superior —válido en un nodo Code, inválido en un módulo— sin necesidad de
exportaciones artificiales. **No hay copia del código**: si la prueba pasa, es
el código que corre en producción.

Cada conversación tiene su propio static data en memoria, así que las pruebas
están aisladas entre sí.

### Escribir una prueba nueva

```js
import { nuevaConversacion, PRELUDIO } from './harness.mjs';

test('mi caso', () => {
  const conv = nuevaConversacion();
  // PRELUDIO = ['hola', '1', 'Juan Perez']  → deja la sesión en tipo_usuario
  const r = conv.guion([...PRELUDIO, '3', '1']).at(-1);
  assert.equal(r.ruta, 'ACR_DIF');
});
```

Métodos disponibles:

| Método | Para qué |
|---|---|
| `enviar(texto, {from, id})` | Un mensaje de texto con el shape real de Meta. |
| `enviarEstado('delivered')` | Un acuse de estado (debe devolver `[]`). |
| `enviarNoTexto('audio')` | Audio, imagen, documento… |
| `enviarEvento(json)` | Un evento crudo, para probar shapes raros. |
| `guion([...])` | Varios mensajes seguidos, devuelve todas las respuestas. |
| `staticData` | Inspeccionar o precargar el estado. |

Opciones de `nuevaConversacion`:

```js
nuevaConversacion({ env: { MERCAMIO_SESSION_TTL_MIN: '30' } })  // variables de entorno
nuevaConversacion({ bloquearEnv: true })                        // simula $env bloqueado
nuevaConversacion({ silencioso: false })                        // muestra console.warn
```

---

## Nivel 2 — El simulador, dentro de Docker

Prueba el flujo completo —webhook, motor, If, ramas, respuesta— sin cuenta de
Meta ni credenciales de Google.

```powershell
powershell -File scripts/simular-conversacion.ps1 -Guion acreedor-diferencia
```

### Los 10 guiones

| Guion | Ruta | Termina en |
|---|---|---|
| `completo` / `cliente-retenciones` | CLI_RET | ticket |
| `cliente-cartera` | CLI_CAR | ticket escalado |
| `proveedor-factura` | PRO_PEN | ticket |
| `proveedor-certificado` | PRO_CER | ticket |
| `acreedor-diferencia` | ACR_DIF | ticket |
| `acreedor-factura` | ACR_PEN | ticket escalado |
| `acreedor-certificado` | ACR_CER | ticket |
| `portal-proveedor` | — | cierre, remite al portal |
| `rechaza-datos` | — | cierre por no consentir |
| `interactivo` | — | escribes tú |

Cada corrida usa un teléfono aleatorio distinto, así que siempre empieza desde
cero. Para retomar una conversación: `-Telefono 573001112233`.

### Repasar todas las rutas de una vez

```powershell
$rutas = 'cliente-retenciones','cliente-cartera','proveedor-factura',
         'proveedor-certificado','acreedor-diferencia','acreedor-factura',
         'acreedor-certificado','portal-proveedor','rechaza-datos'
foreach ($r in $rutas) {
    Write-Host "`n########## $r ##########" -ForegroundColor Magenta
    powershell -File scripts/simular-conversacion.ps1 -Guion $r
}
```

### Sin el script

```powershell
$t = '573001112233'
'hola','1','Juan Perez','1','1','juan@empresa.com' | ForEach-Object {
    $r = Invoke-RestMethod -Uri http://localhost:5678/webhook/mercamio-sim -Method Post `
         -ContentType 'application/json' -Body (@{from=$t; text=$_} | ConvertTo-Json -Compress)
    "$_  ->  [$($r.estado)] $($r.respuesta)"
}
```

### Probar también Google Sheets

En el simulador, el nodo de Sheets viene **deshabilitado**. Para probar el
registro real:

1. Configura la credencial y `MERCAMIO_SHEET_ID` ([04](04-credenciales.md)).
2. Abre el simulador en n8n, clic derecho en **Registrar solicitud en Sheets** →
   **Enable**.
3. Pasa un guion que genere ticket.
4. Comprueba la fila nueva en la hoja.

> Habilitarlo desde la interfaz se pierde en el siguiente
> `importar-workflows.ps1`. Para que sea permanente, cambia el segundo argumento
> de `nodoSheets([440, -100], true)` a `false` en
> [`scripts/build-workflow.mjs`](../scripts/build-workflow.mjs).

---

## Nivel 3 — WhatsApp real

Requiere túnel ([03](03-webhook-whatsapp-tunel.md)) y credenciales
([04](04-credenciales.md)).

Lista de verificación:

- [ ] `Invoke-RestMethod https://<tu-tunel>/healthz` responde `ok`
- [ ] El workflow **V07 (WhatsApp)** está **activo**
- [ ] Meta muestra el webhook verificado y el campo `messages` suscrito
- [ ] Las dos credenciales de WhatsApp asignadas a sus nodos
- [ ] Escribes "hola" y aparece una ejecución en n8n
- [ ] El bot responde
- [ ] `estado_sesion` **avanza** entre mensajes
- [ ] Al completar una ruta, aparece la fila en la hoja
- [ ] **No** llegan respuestas duplicadas

El último punto es el que valida la corrección de BUG-03 y BUG-05: si llegan
mensajes dobles, hay dos workflows activos con el mismo trigger, o el motor no
está descartando los acuses de estado.

---

## Diagnóstico

### El bot repite el saludo en cada mensaje

**El síntoma número uno, y casi nunca es el código.**

`$getWorkflowStaticData` solo se **guarda** en ejecuciones de **producción**.
Causas, por frecuencia:

1. El workflow está **inactivo** → actívalo.
2. Se está llamando a `/webhook-test/...` en vez de `/webhook/...`.
3. Se está usando **Execute workflow** desde el editor.

Comprobar que el estado sí se está guardando:

```powershell
docker compose exec -T postgres psql -U n8n -d n8n -t -A -c "select count(*) from jsonb_object_keys((('{}'::jsonb || coalesce(\"staticData\"::jsonb,'{}'::jsonb))->'global')->'sessions') from workflow_entity where id='mercamioSim00001';"
```

Un número mayor que 0 significa que la persistencia funciona.

> Ojo con la ruta: el static data se guarda bajo la clave `global`, porque el
> motor llama a `$getWorkflowStaticData('global')`. Consultar
> `staticData->'sessions'` devuelve `null` y parece —erróneamente— que no se
> está guardando nada.

### El webhook devuelve 404

El workflow no está activo. El webhook de producción solo existe mientras lo
esté.

```powershell
docker compose exec -T postgres psql -U n8n -d n8n -t -A -F'|' -c "select id, name, active from workflow_entity;"
```

**La causa más habitual: acabas de importar.** `n8n import:workflow` sobrescribe
la fila completa, incluida `active`, y los JSON generados llevan
`active: false`. `importar-workflows.ps1` reactiva lo que estaba activo y
reinicia n8n; si importaste a mano, reactiva tú:

```powershell
docker compose exec n8n n8n update:workflow --id=mercamioSim00001 --active=true
docker compose restart n8n
```

El `restart` no es opcional: la CLI avisa de que la activación no surte efecto
mientras n8n está corriendo, porque el proceso en marcha no vuelve a registrar
los webhooks.

### Respuesta vacía con código 200

**Es correcto.** El motor descartó el evento a propósito:

- acuse de estado de Meta,
- webhook repetido (mismo `message.id`),
- evento sin mensaje.

El motor devuelve `[]`, n8n detiene la rama, y el nodo de respuesta nunca se
ejecuta. Queda registrada una ejecución **exitosa sin datos de salida** — eso
también es normal y no indica ningún fallo.

### Cambié el código y no pasa nada

El código vive en `src/nodes/`, pero lo que ejecuta n8n es el JSON importado.

```powershell
powershell -File scripts/importar-workflows.ps1
# y recarga la página de n8n con F5
```

Si editaste el nodo Code **en la interfaz**, ese cambio se pierde en la
siguiente importación. Llévalo a `src/nodes/`.

### La hoja no recibe filas

En este orden:

1. ¿La ejecución llegó al nodo de Sheets? Míralo en **Executions**.
2. ¿Tomó la rama TRUE? Requiere `has_ticket = true`, es decir una solicitud
   **completada**.
3. ¿`MERCAMIO_SHEET_ID` está definida? `docker compose exec n8n printenv MERCAMIO_SHEET_ID`
4. ¿La pestaña se llama exactamente `Solicitudes`?
5. ¿La cuenta que autorizó tiene permiso de edición?

> El nodo tiene `onError: continueRegularOutput` y 3 reintentos: si Sheets
> falla, el usuario **igual recibe su número de ticket** y el error queda en el
> log para reprocesar. Es deliberado — perder la respuesta al usuario es peor
> que perder momentáneamente la fila. La contrapartida: un fallo de Sheets es
> silencioso desde el punto de vista del usuario, así que hay que revisar las
> ejecuciones periódicamente.

### Mensajes duplicados en WhatsApp

1. ¿Hay dos workflows activos con el trigger de WhatsApp? Solo uno debe estarlo.
2. ¿Se importó dos veces creando duplicados? Con los id fijos de V07 no debería
   pasar, pero revisa la lista de workflows.
3. Si son dos respuestas **distintas** al mismo mensaje, el motor está
   procesando un acuse de estado: revisa la guarda `if (!message) return []`.

### Ver el estado interno

```powershell
# Sesiones vivas
docker compose exec -T postgres psql -U n8n -d n8n -t -A -c "select jsonb_object_keys((('{}'::jsonb || \"staticData\"::jsonb)->'global')->'sessions') from workflow_entity where id='mercamioSim00001';"

# Ejecuciones por estado
docker compose exec -T postgres psql -U n8n -d n8n -t -A -F'|' -c "select status, count(*) from execution_entity group by 1;"

# Variables que ve el contenedor
docker compose exec n8n printenv | Select-String 'MERCAMIO|WEBHOOK'
```

### Reiniciar el estado de las conversaciones

Borra todas las sesiones sin tocar los workflows:

```powershell
docker compose exec -T postgres psql -U n8n -d n8n -c "update workflow_entity set \"staticData\" = null where id like 'mercamio%';"
docker compose restart n8n
```

El `restart` es necesario: n8n mantiene el static data en memoria.

### Empezar completamente de cero

```powershell
docker compose down -v     # BORRA workflows, credenciales e historial
docker compose up -d
# volver a crear la cuenta, reimportar, reasignar credenciales
```

`down -v` solo borra los volúmenes `mercamio_*`. Un volumen `n8n_data` de otro
proyecto en la misma máquina no se toca.

---

## Lo que no está cubierto

Honestamente, para que nadie se confíe:

- **Concurrencia real.** Las pruebas son secuenciales. Dos mensajes del mismo
  usuario en el mismo instante pueden pisarse el estado (*lost update*). Ver
  [05 — Deuda técnica](05-auditoria-workflow.md#deuda-técnica-pendiente).
- **La entrega de Meta.** El harness simula el shape del payload; no simula
  reintentos reales, orden de llegada ni latencias.
- **El nodo de Google Sheets.** No hay prueba automatizada del escritura real.
  Se verifica a mano.
- **Carga.** Nadie ha medido qué pasa con 100 conversaciones simultáneas. El
  tope de `MERCAMIO_MAX_SESSIONS` protege el static data, pero no se ha probado
  bajo presión.
