<#
.SYNOPSIS
  Crea en n8n las dos credenciales de WhatsApp a partir de los valores de .env.

.DESCRIPTION
  El workflow de WhatsApp necesita DOS credenciales distintas, con campos
  distintos:

    whatsAppApi         (enviar)   accessToken + businessAccountId
    whatsAppTriggerApi  (recibir)  clientId + clientSecret   <- App ID y App Secret,
                                                                NO el access token

  Ese segundo par es la confusion mas comun: el trigger no usa el token, usa las
  credenciales de la app de Meta para suscribir el webhook.

  Este script las crea con ID FIJO (mercamioWaApi001 / mercamioWaTrg001), que es
  el que ya referencia el workflow generado. Asi no hay que asignarlas a mano en
  la interfaz.

  El token NUNCA pasa por la terminal ni por un chat: se lee de .env, se escribe
  a un archivo temporal fuera del repositorio, se importa y se borra.

  REQUISITOS en .env (ver docs/09-registrar-numero-whatsapp.md):
    WHATSAPP_TOKEN=EAAxxxx...        token permanente del Usuario del sistema
    WHATSAPP_WABA_ID=1234567890      WhatsApp Business Account ID
    WHATSAPP_APP_ID=1234567890       App ID     (Meta > Configuracion > Basica)
    WHATSAPP_APP_SECRET=abc123...    App Secret (la misma pantalla)

.PARAMETER Verificar
  Solo comprueba que estan creadas; no importa nada.

.EXAMPLE
  powershell -File scripts/crear-credenciales-whatsapp.ps1
  powershell -File scripts/crear-credenciales-whatsapp.ps1 -Verificar
#>
[CmdletBinding()]
param(
    [switch]$Verificar
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

# IDs fijos: scripts/build-workflow.mjs los referencia en el workflow generado.
# Si cambian aqui, hay que cambiarlos alli tambien.
$ID_ENVIAR  = 'mercamioWaApi001'
$ID_RECIBIR = 'mercamioWaTrg001'

function Paso  { param([string]$t) Write-Host "==> $t" -ForegroundColor Cyan }
function Bien  { param([string]$t) Write-Host "    [ok]    $t" -ForegroundColor Green }
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
    $sql = "select id || ' | ' || name || ' | ' || type from credentials_entity where id in ('$ID_ENVIAR','$ID_RECIBIR') order by id;"
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
    Paso 'Credenciales de WhatsApp en n8n'
    $filas = Estado-Actual
    if ($filas.Count -eq 0) {
        Falla 'No hay ninguna. Ejecuta el script sin -Verificar.'
        exit 1
    }
    foreach ($f in $filas) { Bien $f }
    if ($filas.Count -lt 2) {
        Falla 'Falta una de las dos. Vuelve a ejecutar el script sin -Verificar.'
        exit 1
    }
    Write-Host ''
    Write-Host 'Las dos estan creadas. Siguiente: activar el workflow de WhatsApp.' -ForegroundColor Green
    Write-Host '  powershell -File scripts/activar-whatsapp.ps1'
    exit 0
}

# ------------------------------------------------------------- 1. lectura
Paso 'Leyendo la configuracion de .env'

$campos = [ordered]@{
    WHATSAPP_TOKEN      = 'token permanente (Usuario del sistema)'
    WHATSAPP_WABA_ID    = 'WhatsApp Business Account ID'
    WHATSAPP_APP_ID     = 'App ID de la app de Meta'
    WHATSAPP_APP_SECRET = 'App Secret de la app de Meta'
}

$valores = @{}
$faltan = @()
foreach ($c in $campos.Keys) {
    $v = Leer-Env $c
    $valores[$c] = $v
    if (-not $v) { $faltan += "$c  ($($campos[$c]))" }
}

if ($faltan.Count -gt 0) {
    Falla 'Faltan valores en .env:'
    foreach ($f in $faltan) { Write-Host "      $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '    Donde encontrar cada uno: docs/09-registrar-numero-whatsapp.md' -ForegroundColor DarkGray
    Write-Host '      TOKEN y WABA_ID  -> Meta > WhatsApp > API Setup' -ForegroundColor DarkGray
    Write-Host '      APP_ID y SECRET  -> Meta > Configuracion > Basica' -ForegroundColor DarkGray
    exit 1
}

# Aviso barato que ahorra un diagnostico largo: el token temporal de API Setup
# es notablemente mas corto que uno de Usuario del sistema.
if ($valores.WHATSAPP_TOKEN.Length -lt 100) {
    Write-Host "    [aviso] El token tiene solo $($valores.WHATSAPP_TOKEN.Length) caracteres." -ForegroundColor Yellow
    Write-Host '            Los permanentes suelen pasar de 150. Si es el temporal de' -ForegroundColor Yellow
    Write-Host '            API Setup, el bot dejara de responder en 24 h (docs/09, paso 3).' -ForegroundColor Yellow
}
Bien 'Los cuatro valores estan presentes.'

# --------------------------------------------------------- 2. n8n arriba?
Paso 'Comprobando n8n'
$estado = (docker compose ps --format '{{.Service}}:{{.State}}' 2>$null) -join "`n"
if ($estado -notmatch 'n8n:running') {
    Falla 'El contenedor de n8n no esta corriendo. Ejecuta: docker compose up -d'
    exit 1
}
Bien 'n8n esta arriba.'

# ------------------------------------------------------------ 3. importar
Paso 'Creando las credenciales'

# El archivo lleva los secretos EN CLARO. Va al temporal del sistema, nunca al
# repositorio, y se borra pase lo que pase.
$tmpLocal = Join-Path $env:TEMP ("mercamio-cred-" + [guid]::NewGuid().ToString('N') + ".json")
$rutaCtr = '/tmp/mercamio-cred.json'

try {
    $credenciales = @(
        @{
            id   = $ID_ENVIAR
            name = 'MERCAMIO WhatsApp - enviar'
            type = 'whatsAppApi'
            data = @{
                accessToken       = $valores.WHATSAPP_TOKEN
                businessAccountId = $valores.WHATSAPP_WABA_ID
            }
        },
        @{
            id   = $ID_RECIBIR
            name = 'MERCAMIO WhatsApp - recibir'
            type = 'whatsAppTriggerApi'
            data = @{
                clientId     = $valores.WHATSAPP_APP_ID
                clientSecret = $valores.WHATSAPP_APP_SECRET
            }
        }
    )

    # -Encoding ascii a proposito: Set-Content en 5.1 usa la codificacion ANSI
    # del sistema y Out-File mete BOM. Un BOM al principio rompe el JSON.parse
    # del importador. Los tokens de Meta son ASCII puro.
    ($credenciales | ConvertTo-Json -Depth 6) | Set-Content -Path $tmpLocal -Encoding ascii

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
        $salidaTexto -split "`n" |
            Where-Object { $_ -notmatch 'Error tracking' -and $_ -notmatch '^\s+at ' } |
            ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        exit 1
    }
    Bien 'Importadas y cifradas con N8N_ENCRYPTION_KEY.'
}
finally {
    # Limpieza en los dos lados, ocurra lo que ocurra.
    if (Test-Path $tmpLocal) { Remove-Item $tmpLocal -Force -ErrorAction SilentlyContinue }

    # -u root es obligatorio: `docker compose cp` deja el archivo como root y
    # n8n corre como el usuario `node`, que no puede borrarlo. Sin esto, el
    # archivo con el token EN CLARO se queda dentro del contenedor.
    Invocar-Nativo { docker compose exec -T -u root n8n rm -f $rutaCtr } | Out-Null
}

# ------------------------------------------------------------ 4. verificar
Paso 'Verificando'
$filas = Estado-Actual
foreach ($f in $filas) { Bien $f }
if ($filas.Count -lt 2) {
    Falla 'Se esperaban 2 credenciales. Revisa la salida de arriba.'
    exit 1
}

# Comprobacion de que el archivo en claro no sobrevivio.
$previo = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { docker compose exec -T n8n ls $rutaCtr 2>$null | Out-Null; $existe = ($LASTEXITCODE -eq 0) }
finally { $ErrorActionPreference = $previo }
if ($existe) {
    Falla "ATENCION: $rutaCtr sigue dentro del contenedor con los secretos en claro."
    Falla "Borralo: docker compose exec -u root n8n rm -f $rutaCtr"
}
else {
    Bien 'El archivo temporal con los secretos fue eliminado.'
}

Write-Host ''
Write-Host 'Listo. El workflow de WhatsApp ya referencia estas credenciales por ID.' -ForegroundColor Green
Write-Host ''
Write-Host 'Siguiente paso:' -ForegroundColor Cyan
Write-Host '  powershell -File scripts/activar-whatsapp.ps1'
Write-Host ''
Write-Host 'Ese script activa el workflow y te da la URL exacta para pegar en Meta.'
Write-Host 'Antes conviene comprobar el token:' -ForegroundColor DarkGray
Write-Host '  powershell -File scripts/verificar-whatsapp.ps1' -ForegroundColor DarkGray
