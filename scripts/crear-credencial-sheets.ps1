<#
.SYNOPSIS
  Crea en n8n la credencial de Google Sheets a partir de la clave JSON de una
  cuenta de servicio.

.DESCRIPTION
  El nodo "Registrar solicitud en Sheets" usa una CUENTA DE SERVICIO, no OAuth2.

  Por que no OAuth2: MERCAMIO no usa Google Workspace, asi que la pantalla de
  consentimiento solo puede ser Externa. Una app externa en estado "Testing"
  hace que Google caduque el refresh token a los 7 dias. Y como el nodo lleva
  onError 'continueRegularOutput', el bot seguiria entregando numeros de ticket
  sin escribir nada en la hoja: un fallo silencioso una semana despues de
  arrancar, que solo se descubre cuando un proveedor reclama.

  Una cuenta de servicio firma su propio JWT: no caduca, no tiene pantalla de
  consentimiento y no depende de ninguna URI de redireccion. Eso ultimo importa
  porque scripts/tunel-rapido.ps1 reescribe WEBHOOK_URL, y n8n deriva de ahi el
  callback de OAuth: con tunel, reconectar una credencial OAuth es imposible
  porque el host de trycloudflare.com cambia en cada arranque.

  La credencial se crea con ID FIJO (mercamioSheets01), que es el que ya
  referencia el workflow generado por scripts/build-workflow.mjs. Asi no hay que
  asignarla a mano en la interfaz despues de cada importacion.

  La clave privada NUNCA pasa por la terminal ni por un chat: se lee del archivo
  JSON, se escribe a un temporal fuera del repositorio, se importa y se borra.

  REQUISITOS en .env:
    GOOGLE_SA_KEY_FILE=C:\Users\tu-usuario\.secretos\mercamio-sa.json
    MERCAMIO_SHEET_ID=1AbC...   (el tramo entre /d/ y /edit de la URL)

  Y en Google, antes de ejecutarlo:
    1. Hoja creada con la pestana llamada "Solicitudes" y los encabezados de
       sheets/plantilla-solicitudes.csv en la fila 1.
    2. La hoja COMPARTIDA COMO EDITOR con el correo de la cuenta de servicio.
       Sin esto el nodo falla con "The caller does not have permission".
       El script imprime ese correo al terminar.

.PARAMETER Verificar
  Solo comprueba que la credencial existe; no importa nada.

.EXAMPLE
  powershell -File scripts/crear-credencial-sheets.ps1
  powershell -File scripts/crear-credencial-sheets.ps1 -Verificar
#>
[CmdletBinding()]
param(
    [switch]$Verificar
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

# ID fijo: scripts/build-workflow.mjs lo referencia en el workflow generado.
# Si cambia aqui, hay que cambiarlo alli tambien.
$ID_SHEETS = 'mercamioSheets01'
$NOMBRE    = 'MERCAMIO Google Sheets'

function Paso  { param([string]$t) Write-Host "==> $t" -ForegroundColor Cyan }
function Bien  { param([string]$t) Write-Host "    [ok]    $t" -ForegroundColor Green }
function Ojo   { param([string]$t) Write-Host "    [aviso] $t" -ForegroundColor Yellow }
function Falla { param([string]$t) Write-Host "    [fallo] $t" -ForegroundColor Red }

# Ver docs/01: redirigir stderr de un ejecutable nativo lanza NativeCommandError
# en PowerShell 5.1 y con ErrorActionPreference='Stop' mata el script.
function Invocar-Nativo {
    param([Parameter(Mandatory = $true)][scriptblock]$Comando)
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Comando | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $previo }
}

function Leer-Env {
    param([string]$Clave)
    $ruta = Join-Path $raiz '.env'
    if (-not (Test-Path $ruta)) { return '' }
    foreach ($linea in (Get-Content $ruta -Encoding UTF8)) {
        if ($linea -match "^\s*$([regex]::Escape($Clave))\s*=\s*(.*)$") {
            return $matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return ''
}

function Estado-Actual {
    $sql = "select id || ' | ' || name || ' | ' || type from credentials_entity where id = '$ID_SHEETS';"
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $filas = docker compose exec -T postgres psql -U n8n -d n8n -t -A -c $sql
    }
    finally { $ErrorActionPreference = $previo }
    return @($filas | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# ---------------------------------------------------------------- verificar
if ($Verificar) {
    Paso 'Credencial de Google Sheets en n8n'
    $filas = Estado-Actual
    if ($filas.Count -eq 0) {
        Falla 'No existe. Ejecuta el script sin -Verificar.'
        exit 1
    }
    foreach ($f in $filas) { Bien $f }
    Write-Host ''
    Write-Host 'La credencial esta creada.' -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------- 1. la clave
Paso 'Leyendo la clave de la cuenta de servicio'

$rutaClave = Leer-Env 'GOOGLE_SA_KEY_FILE'
if (-not $rutaClave) {
    Falla 'Falta GOOGLE_SA_KEY_FILE en .env.'
    Write-Host '      Debe apuntar al JSON que descargaste de Google Cloud,' -ForegroundColor Red
    Write-Host '      en una carpeta FUERA de este repositorio. Por ejemplo:' -ForegroundColor Red
    Write-Host '        GOOGLE_SA_KEY_FILE=C:\Users\hamil\.secretos\mercamio-sa.json' -ForegroundColor DarkGray
    exit 1
}

if (-not (Test-Path $rutaClave)) {
    Falla "No existe el archivo: $rutaClave"
    exit 1
}

# La clave privada de una cuenta de servicio da acceso permanente a la hoja y no
# caduca. Dentro del repositorio es cuestion de tiempo que alguien la commitee;
# el hook de pre-commit la atraparia, pero es mejor que ni siquiera este ahi.
$claveCompleta = (Resolve-Path $rutaClave).Path
$raizCompleta  = (Resolve-Path $raiz).Path
if ($claveCompleta.StartsWith($raizCompleta, [StringComparison]::OrdinalIgnoreCase)) {
    Falla 'La clave esta DENTRO del repositorio. Muevela fuera antes de seguir.'
    Write-Host "      clave: $claveCompleta" -ForegroundColor Red
    Write-Host "      repo:  $raizCompleta" -ForegroundColor Red
    exit 1
}

try {
    $sa = Get-Content $claveCompleta -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Falla "El archivo no es JSON valido: $($_.Exception.Message)"
    exit 1
}

if ($sa.type -ne 'service_account') {
    Falla "El JSON no es de una cuenta de servicio (type = '$($sa.type)')."
    Write-Host '      En Google Cloud: IAM y administracion > Cuentas de servicio >' -ForegroundColor Red
    Write-Host '      tu cuenta > Claves > Agregar clave > Crear clave nueva > JSON.' -ForegroundColor Red
    exit 1
}

foreach ($campo in @('client_email', 'private_key')) {
    if (-not $sa.$campo) {
        Falla "Al JSON le falta el campo '$campo'."
        exit 1
    }
}

Bien "Cuenta de servicio: $($sa.client_email)"

# ------------------------------------------------------- 2. el ID de la hoja
$sheetId = Leer-Env 'MERCAMIO_SHEET_ID'
if (-not $sheetId) {
    Ojo 'MERCAMIO_SHEET_ID esta vacio en .env.'
    Ojo 'La credencial se crea igual, pero el nodo no sabra en que hoja escribir.'
}
else {
    Bien "MERCAMIO_SHEET_ID configurado ($($sheetId.Length) caracteres)."
}

# --------------------------------------------------------- 3. n8n arriba?
Paso 'Comprobando n8n'
$estado = (docker compose ps --format '{{.Service}}:{{.State}}' 2>$null) -join "`n"
if ($estado -notmatch 'n8n:running') {
    Falla 'El contenedor de n8n no esta corriendo. Ejecuta: docker compose up -d'
    exit 1
}
Bien 'n8n esta arriba.'

# ------------------------------------------------------------ 4. importar
Paso 'Creando la credencial'

# El archivo lleva la clave privada EN CLARO. Va al temporal del sistema, nunca
# al repositorio, y se borra pase lo que pase.
$tmpLocal = Join-Path $env:TEMP ("mercamio-sheets-" + [guid]::NewGuid().ToString('N') + ".json")
$rutaCtr = '/tmp/mercamio-sheets.json'

try {
    $credenciales = @(
        @{
            id   = $ID_SHEETS
            name = $NOMBRE
            type = 'googleApi'
            data = @{
                email       = $sa.client_email
                privateKey  = $sa.private_key
                inpersonate = $false
            }
        }
    )

    # PowerShell 5.1 COLAPSA un array de un solo elemento a objeto al
    # serializar, y `n8n import:credentials` rechaza el archivo con "File does
    # not seem to contain credentials. Make sure the credentials are contained
    # in an array." El script de WhatsApp no lo sufre porque manda dos.
    # -AsArray no existe en 5.1, asi que se envuelve a mano.
    $json = $credenciales | ConvertTo-Json -Depth 6
    if (-not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }

    # -Encoding ascii a proposito: Set-Content en 5.1 usa la codificacion ANSI
    # del sistema y Out-File mete BOM. Un BOM al principio rompe el JSON.parse
    # del importador. Una clave PEM en base64 es ASCII puro.
    $json | Set-Content -Path $tmpLocal -Encoding ascii

    $c1 = Invocar-Nativo { docker compose cp $tmpLocal ("n8n:" + $rutaCtr) }
    if ($c1 -ne 0) { Falla "No se pudo copiar el archivo al contenedor (codigo $c1)."; exit 1 }

    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = docker compose exec -T n8n n8n import:credentials --input=$rutaCtr
        $codigo = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previo }

    $salidaTexto = ($salida -join "`n")
    if ($codigo -ne 0 -or $salidaTexto -notmatch 'Successfully imported') {
        Falla 'La importacion fallo:'
        $salida | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        exit 1
    }
    Bien 'Credencial importada.'
}
finally {
    Remove-Item $tmpLocal -ErrorAction SilentlyContinue
    # -u root es obligatorio: `docker compose cp` deja el archivo con propietario
    # root, y el proceso de n8n corre como usuario sin privilegios. Sin esto el
    # borrado falla con "Operation not permitted" y la clave privada se queda EN
    # CLARO dentro del contenedor hasta el siguiente `docker compose down`.
    $codigoRm = Invocar-Nativo { docker compose exec -T -u root n8n rm -f $rutaCtr }
    if ($codigoRm -ne 0) {
        Falla 'No se pudo borrar la copia temporal DENTRO del contenedor.'
        Write-Host "      Borrala a mano: docker compose exec -u root n8n rm -f $rutaCtr" -ForegroundColor Red
    }
}

# --------------------------------------------------------- 5. comprobacion
Paso 'Comprobando el resultado'

# No basta con que el `rm` devolviera 0: se comprueba que el archivo con la
# clave privada EN CLARO no sobrevivio dentro del contenedor.
$previo = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { docker compose exec -T n8n ls $rutaCtr 2>$null | Out-Null; $sobrevivio = ($LASTEXITCODE -eq 0) }
finally { $ErrorActionPreference = $previo }
if ($sobrevivio) {
    Falla "ATENCION: $rutaCtr sigue dentro del contenedor con la clave privada en claro."
    Falla "Borralo: docker compose exec -u root n8n rm -f $rutaCtr"
}
else {
    Bien 'El archivo temporal con la clave fue eliminado.'
}

$filas = Estado-Actual
if ($filas.Count -eq 0) {
    Falla 'La credencial no aparece en la base de datos.'
    exit 1
}
foreach ($f in $filas) { Bien $f }

Write-Host ''
Write-Host 'Listo. Falta UN paso que no se puede automatizar:' -ForegroundColor Green
Write-Host ''
Write-Host '  Comparte la hoja de calculo COMO EDITOR con este correo:' -ForegroundColor Yellow
Write-Host "      $($sa.client_email)" -ForegroundColor White
Write-Host ''
Write-Host '  Una cuenta de servicio no es miembro de tu organizacion ni ve tu' -ForegroundColor DarkGray
Write-Host '  Drive: si no compartes la hoja con ella, el nodo falla con' -ForegroundColor DarkGray
Write-Host '  "The caller does not have permission".' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Despues, para probar la escritura sin depender de WhatsApp:' -ForegroundColor Green
Write-Host '      1. Pon MERCAMIO_SIM_SHEETS=true en .env' -ForegroundColor DarkGray
Write-Host '      2. powershell -File scripts/importar-workflows.ps1' -ForegroundColor DarkGray
Write-Host '      3. powershell -File scripts/simular-conversacion.ps1 -Guion acreedor-diferencia' -ForegroundColor DarkGray
Write-Host '      4. La fila debe aparecer en la hoja "Solicitudes".' -ForegroundColor DarkGray
