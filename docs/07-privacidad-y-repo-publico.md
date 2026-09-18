# 07 — Privacidad y repositorio público

Lee esto **antes** de hacer `git push` a un repositorio público.

---

## Qué contenía el JSON original

El archivo `MERCAMIO - ChatBOT contable V06.json`, tal como estaba, llevaba en
texto plano:

| Dato | Cantidad | Por qué importa |
|---|---|---|
| Correos internos de contabilidad | 5 direcciones | **Datos personales** de empleados identificables. Alimenta suplantación y phishing dirigido. |
| ID de la hoja de cálculo | 1 | Identificador directo de un documento de Drive de MERCAMIO. |
| IDs de credenciales de n8n | 3 | Revelan la estructura interna de la instancia. |
| `instanceId` de n8n | 1 | Huella identificable de la instalación. |

Los correos son el problema serio. Son buzones nominales del área contable de
MERCAMIO, atendidos por personas identificables. Un repositorio público es
indexado por buscadores, clonado por bots y replicado en espejos de conjuntos
de datos.

Un correo interno publicado se convierte en el destinatario de un correo que
dice *"factura pendiente, ver adjunto"*. Y el departamento cuyo trabajo es
tramitar facturas de proveedores es exactamente el que menos puede permitirse
recibirlo.

> **Git no olvida.** Un `git rm` posterior deja el dato en el historial. Un
> `push --force` no elimina los forks, ni la caché de GitHub, ni lo que los
> rastreadores ya se llevaron. La única vez que esto se decide es **antes** del
> primer push.

---

## Cómo está resuelto

La configuración sensible salió del código y entró por variables de entorno.

### Responsables y SLA

En el código, marcadores neutros:

```js
const routes = {
  CLI_RET: { owner: 'retenciones@pendiente.local', sla: 'Por confirmar', ... },
  PRO_PEN: { owner: 'proveedores.facturas@pendiente.local', sla: '2 dias', ... },
  ...
};
```

En `.env` (que **no se versiona**), los valores reales:

```ini
MERCAMIO_ROUTES_JSON={"CLI_RET":{"owner":"<buzon interno real>","sla":"3 dias"},...}
```

El motor fusiona lo uno sobre lo otro:

```js
const overrideRutas = env('MERCAMIO_ROUTES_JSON', '');
if (overrideRutas) {
  const parsed = JSON.parse(overrideRutas);
  for (const [codigo, parche] of Object.entries(parsed)) {
    if (routes[codigo]) routes[codigo] = { ...routes[codigo], ...parche };
  }
}
```

Con `.env` presente, el bot usa los correos reales. Sin él —al clonar el
repositorio— usa los marcadores y sigue funcionando. Verificado por las pruebas
`MERCAMIO_ROUTES_JSON sobreescribe responsable y SLA` y `un
MERCAMIO_ROUTES_JSON corrupto no tumba el bot`.

### ID de la hoja

El nodo de Google Sheets lo lee del entorno:

```json
"documentId": { "__rl": true, "value": "={{ $env.MERCAMIO_SHEET_ID }}", "mode": "id" }
```

### Credenciales

El JSON generado **no lleva bloque `credentials`**. Se asignan una vez en la
interfaz y quedan cifradas en la base de datos con `N8N_ENCRYPTION_KEY`, que
vive en `.env`.

### El histórico

El JSON original se conserva en local y está bloqueado en `.gitignore`:

```
workflows/historico/V06-original-CON-DATOS-REALES.json
```

Lo que **sí** se versiona es `V06-original-sanitizado.json`, con 11 valores
redactados, para que la auditoría de [05](05-auditoria-workflow.md) tenga
referencia. Verificado: cero correos `@mercamio.com` restantes.

---

## Qué bloquea `.gitignore`

```
.claude/  .claude.json  CLAUDE.md  .mcp.json   ← config de Claude Code, local
.env  .env.*  !.env.example                     ← secretos
*.pem  *.key  *.p12                             ← claves
n8n-credentials*.json  credenciales*.json       ← exportaciones con tokens en claro
data/  volumes/  pgdata/  *.sqlite              ← datos de n8n
workflows/historico/V06-original-CON-DATOS-REALES.json
```

`CLAUDE.md` está excluido porque pediste llevar la configuración de Claude en
local. Es una decisión reversible: si más adelante quieres compartir las
instrucciones del proyecto con el equipo, quita esa línea.

---

## Primera barrera: el hook de pre-commit

Las comprobaciones de abajo son manuales y hay que acordarse de hacerlas. El
hook de [.githooks/pre-commit](../.githooks/pre-commit) no se olvida: revisa
las lineas anadidas de cada commit y lo bloquea si encuentra un secreto.

```powershell
git config core.hooksPath .githooks   # una vez por clon
```

Lo mas util que hace es buscar **los valores literales de tu `.env`**. Si una
cadena esta en tu `.env` y aparece en un commit, es una fuga sin ambiguedad
posible — cero falsos positivos.

No cubre lo que ya esta en el historial. Para eso, lo de abajo.

---

## Verificar antes del push

Ejecuta esto y **lee la salida**. No des el push si algo aparece.

```powershell
# 1. ¿Hay correos de MERCAMIO en lo que se va a subir? (incluidos los docs)
git grep -nI -E '[A-Za-z0-9._%+-]+@mercamio\.com'

# 2. ¿El ID de la hoja de producción? (se lee de .env, no se escribe aquí)
$id = ((Get-Content .env | Select-String '^MERCAMIO_SHEET_ID=') -split '=', 2)[1]
if ($id) { git grep -nI $id }

# 3. ¿Algo que parezca token, clave o secreto?
git grep -nIi -E '(api[_-]?key|secret|token|password|passwd)\s*[:=]\s*["'']?[A-Za-z0-9_\-]{16,}'

# 4. ¿Qué archivos se subirían exactamente?
git ls-files

# 5. ¿.env está fuera?
git check-ignore -v .env workflows/historico/V06-original-CON-DATOS-REALES.json
```

La primera comprobación no excluye ninguna ruta: ni el código, ni la
documentación, ni los JSON generados deben contener un correo real de MERCAMIO.
La única coincidencia aceptable es el literal `@mercamio.com` sin buzón delante,
como en esta misma frase. Cualquier dirección completa es un fallo.

Durante la preparación de este repositorio esa comprobación encontró dos fugas
reales: una dirección auténtica copiada por descuido en `.env.example` como si
fuera un marcador, y otra citada como ejemplo en este propio documento. Ejecuta
las cinco de verdad; no asumas que están bien.

Si algo aparece **y ya hiciste commit**, no basta con borrarlo: hay que
reescribir el historial (`git filter-repo`) y, si ya está en remoto, rotar todo
lo expuesto. Es mucho más barato revisarlo ahora.

---

## Antes de publicarlo: tres preguntas

### 1. ¿Puede publicarse una automatización de procesos internos?

El repositorio describe, con precisión, cómo MERCAMIO gestiona retenciones,
cartera, facturas pendientes y certificados: los pasos, los datos que se piden,
quién atiende cada caso y en cuánto tiempo. Eso ya no es código, es un mapa de
un proceso financiero.

No es un secreto industrial, pero tampoco es neutro: le ahorra el trabajo de
reconocimiento a quien quiera construir un pretexto creíble. *"Buenas, soy del
área de cartera, necesito confirmar el comprobante de radicación de la factura
FE-10023"* es mucho más convincente cuando el atacante sabe que ese es
exactamente el dato que el proceso pide.

Esta decisión no es técnica. **Pregúntale al área de TI o de riesgos de
MERCAMIO.**

### 2. ¿Aporta algo que sea público?

Los motivos habituales para publicar —recibir contribuciones, servir de
portafolio, reutilizar entre proyectos— aplican de forma limitada aquí: el
motor está muy acoplado al proceso contable de MERCAMIO. Un tercero no puede
usarlo sin reescribir las 9 rutas.

Si el objetivo es **compartir el patrón** (n8n + máquina de estados testeable +
build reproducible), eso se logra mejor con un repositorio genérico sin las
rutas de negocio.

Si el objetivo es **tener el proyecto en Git para versionarlo**, un repositorio
**privado** da exactamente lo mismo: historial, ramas, respaldo, colaboración.
Sin ninguna de las contrapartidas.

### 3. ¿Quién responde si sale mal?

En un repositorio privado, un descuido se corrige. En uno público, la exposición
es inmediata e irreversible.

---

## Recomendación

**Privado.** El repositorio cumple todo lo que pediste —versionado, Docker,
documentación, instalación reproducible— igual de bien en privado, y el único
beneficio real que añade lo público es que cualquiera pueda leerlo, que no es
algo que necesites.

Si después de esto quieres público: el repositorio ya está preparado
técnicamente para soportarlo. Ejecuta las cinco comprobaciones de arriba, y
antes valida con TI la pregunta 1.

```powershell
# Privado (recomendado)
gh repo create mercamio-chatbot-contable --private --source=. --remote=origin
git push -u origin main

# Público (solo tras validar con TI y pasar las cinco comprobaciones)
gh repo create mercamio-chatbot-contable --public --source=. --remote=origin
git push -u origin main
```

---

## Si aun así se publica

Mínimos exigibles:

1. **Rotar el token de WhatsApp y el Client Secret de Google.** Nunca estuvieron
   en el repositorio, pero rotar antes de un cambio de exposición es higiene
   básica.
2. **Añadir un `LICENSE`.** Sin licencia, nadie puede usarlo legalmente — y si
   la intención es no permitirlo, mejor que sea explícito.
3. **Cambiar la hoja de producción por una de pruebas** mientras el ID esté en
   circulación, aunque esté redactado.
4. **Activar el escaneo de secretos** de GitHub (Settings → Code security).
5. **Anotar en el README** que los correos de `MERCAMIO_ROUTES_JSON` son
   internos y no deben incluirse en ningún PR.
