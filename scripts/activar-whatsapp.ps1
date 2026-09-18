<#
.SYNOPSIS
  Activa el workflow de WhatsApp y muestra la URL exacta que pide Meta.

.DESCRIPTION
  Resuelve el problema de "n8n dice que esta activo pero no escucha".

  El WhatsApp Trigger NO se puede activar sin credenciales. Si faltan, n8n deja
  active=true en la base de datos y reintenta en bucle con espera creciente,
  mientras la interfaz muestra el interruptor en verde. El webhook nunca llega a
  registrarse y Meta no puede entregar nada.

  Este script distingue las dos cosas: comprueba que el webhook aparezca de
  verdad en la tabla webhook_entity, que es la unica prueba de que n8n esta
  escuchando. Si no aparece, lo dice y explica por que.

  Tambien resuelve una circularidad aparente que hace perder tardes:

      Meta necesita la URL del webhook
        -> n8n no genera la URL sin credencial
          -> la credencial viene de Meta

  Se rompe asi: el token sale de "API Setup", que no necesita webhook. Con el
  token creas la credencial, activas, y ENTONCES existe la URL.

.PARAMETER Desactivar
  Apaga el workflow de WhatsApp (util mientras no haya credenciales).

.EXAMPLE
  powershell -File scripts/activar-whatsapp.ps1
  powershell -File scripts/activar-whatsapp.ps1 -Desactivar
#>
[CmdletBinding()]
param(
    [switch]$Desactivar
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

$ID_WF = 'mercamioWa000001'

function Paso  { param([string]$t) Write-Host "==> $t" -ForegroundColor Cyan }
function Bien  { param([string]$t) Write-Host "    [ok]    $t" -ForegroundColor Green }
function Ojo   { param([string]$t) Write-Host "    [aviso] $t" -ForegroundColor Yellow }
function Falla { param([string]$t) Write-Host "    [fallo] $t" -ForegroundColor Red }

function Invocar-Nativo {
    param([Parameter(Mandatory = $true)][scriptblock]$Comando)
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Comando | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $previo }
}

function Salida-Nativa {
    param([Parameter(Mandatory = $true)][scriptblock]$Comando)
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Comando) -join "`n" }
    finally { $ErrorActionPreference = $previo }
}

# OJO con las comillas dobles en el SQL: al pasar un argumento a un ejecutable
# nativo, PowerShell 5.1 se come las comillas embebidas. Un
# `select "webhookPath" ...` llega a psql como `select webhookPath ...`, y
# PostgreSQL pliega a minusculas los identificadores sin comillas:
#     ERROR: column "webhookpath" does not exist
# Por eso las consultas usan row_to_json(t), que no necesita citar ninguna
# columna, y el filtrado se hace despues en PowerShell.
function Consultar {
    param([string]$Sql)
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $r = docker compose exec -T postgres psql -U n8n -d n8n -t -A -c $Sql }
    finally { $ErrorActionPreference = $previo }
    return @($r | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# Devuelve los webhooks registrados del workflow, como objetos.
function Webhooks-Registrados {
    $filas = Consultar 'select row_to_json(t)::text from webhook_entity t;'
    $salida = @()
    foreach ($f in $filas) {
        try { $o = $f | ConvertFrom-Json } catch { continue }
        if ($o.workflowId -eq $ID_WF) { $salida += $o }
    }
    return $salida
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

function Esperar-n8n {
    foreach ($i in 1..40) {
        Start-Sleep -Seconds 3
        try {
            # 127.0.0.1 y no localhost: ver docs/01 (resolucion a ::1).
            if ((Invoke-RestMethod -Uri 'http://127.0.0.1:5678/healthz' -TimeoutSec 5).status -eq 'ok') { return $true }
        }
        catch { }
    }
    $salud = (docker inspect --format '{{.State.Health.Status}}' mercamio-n8n 2>$null) -join ''
    return ($salud.Trim() -eq 'healthy')
}

# --------------------------------------------------------------- desactivar
if ($Desactivar) {
    Paso 'Desactivando el workflow de WhatsApp'
    Invocar-Nativo { docker compose exec -T n8n n8n update:workflow --id=$ID_WF --active=false } | Out-Null
    Invocar-Nativo { docker compose restart n8n } | Out-Null
    if (Esperar-n8n) { Bien 'Desactivado. n8n volvio a responder.' }
    else { Falla 'n8n no volvio. Revisa: docker compose logs n8n' ; exit 1 }
    exit 0
}

# ------------------------------------------------------------ credenciales
Paso 'Comprobando las credenciales'

$creds = Consultar "select id from credentials_entity where id in ('mercamioWaApi001','mercamioWaTrg001');"
if ($creds.Count -lt 2) {
    Falla "Solo hay $($creds.Count) de las 2 credenciales necesarias."
    Write-Host ''
    Write-Host '    El WhatsApp Trigger NO se activa sin credenciales. n8n dejaria' -ForegroundColor Red
    Write-Host '    el workflow como activo y reintentaria en bucle sin escuchar nada.' -ForegroundColor Red
    Write-Host ''
    Write-Host '    Crealas primero:' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/crear-credenciales-whatsapp.ps1' -ForegroundColor DarkGray
    exit 1
}
Bien 'Las dos credenciales existen.'

# ---------------------------------------------------------------- activar
Paso 'Activando el workflow'
Invocar-Nativo { docker compose exec -T n8n n8n update:workflow --id=$ID_WF --active=true } | Out-Null

# El reinicio es obligatorio: la CLI avisa de que la activacion no surte efecto
# mientras n8n esta corriendo, porque el proceso no reregistra los webhooks.
Paso 'Reiniciando n8n para registrar el webhook'
Invocar-Nativo { docker compose restart n8n } | Out-Null
if (-not (Esperar-n8n)) {
    Falla 'n8n no volvio a responder. Revisa: docker compose logs n8n'
    exit 1
}
Bien 'n8n arriba.'

# --------------------------------------------- se registro DE VERDAD?
Paso 'Comprobando el registro local del webhook'

# active=true en workflow_entity NO significa que este escuchando: solo que
# alguien lo marco. La fila en webhook_entity prueba el registro LOCAL.
Start-Sleep -Seconds 3
$webhooks = Webhooks-Registrados

if ($webhooks.Count -eq 0) {
    Falla 'El webhook no se registro ni siquiera en local.'
    Write-Host ''
    Write-Host '    Mira el motivo:' -ForegroundColor DarkGray
    Write-Host '      docker compose logs n8n --tail 40 | Select-String "Activation"' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Si dice "Node does not have any credentials set", el nodo no' -ForegroundColor DarkGray
    Write-Host '    referencia las credenciales: reimporta el workflow.' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/importar-workflows.ps1' -ForegroundColor DarkGray
    exit 1
}
foreach ($w in $webhooks) { Bien "local: $($w.method) /webhook/$($w.webhookPath)" }

# ------------------------------------ Meta acepto la suscripcion?
Paso 'Comprobando que Meta acepto la suscripcion'

# Este es el paso que de verdad decide. Al activar, el WhatsApp Trigger llama a
# la Graph API para suscribir la app al objeto whatsapp_business_account, con
# SU PROPIA callback_url y verify_token. Si Meta lo rechaza, n8n deja las filas
# locales puestas y reintenta en bucle con espera creciente, mientras la
# interfaz sigue mostrando el workflow en verde.
$logs = Salida-Nativa { docker compose logs n8n --tail 120 }
$fallos = @($logs -split "`n" | Where-Object { $_ -match 'Activation of workflow' -and $_ -match $ID_WF -and $_ -match 'did fail' })

if ($fallos.Count -gt 0) {
    $ultimo = $fallos[-1]
    $motivo = 'desconocido'
    $m = [regex]::Match($ultimo, 'did fail with error:\s*"([^"]+)"')
    if ($m.Success) { $motivo = $m.Groups[1].Value }

    Falla "Meta rechazo la suscripcion: $motivo"
    Write-Host ''
    Write-Host '    El workflow figura activo pero NO va a recibir mensajes.' -ForegroundColor Red
    Write-Host ''
    Write-Host '    Traduccion de los motivos mas comunes:' -ForegroundColor DarkGray
    Write-Host '      "Bad request - please check your parameters"' -ForegroundColor DarkGray
    Write-Host '           App ID o App Secret incorrectos, o la app no tiene' -ForegroundColor DarkGray
    Write-Host '           permiso sobre la WABA. Comprueba con:' -ForegroundColor DarkGray
    Write-Host '             powershell -File scripts/verificar-whatsapp.ps1' -ForegroundColor DarkGray
    Write-Host '      "...already has a webhook subscription..."' -ForegroundColor DarkGray
    Write-Host '           Ya hay un webhook configurado A MANO en el panel de Meta,' -ForegroundColor DarkGray
    Write-Host '           o de otro n8n. Borralo en Meta: WhatsApp > Configuration >' -ForegroundColor DarkGray
    Write-Host '           Webhook. n8n lo registra solo, no hay que ponerlo a mano.' -ForegroundColor DarkGray
    Write-Host '      "Invalid OAuth access token"' -ForegroundColor DarkGray
    Write-Host '           El App Secret no corresponde al App ID.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Apaga el workflow mientras lo resuelves, para cortar el bucle:' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/activar-whatsapp.ps1 -Desactivar' -ForegroundColor DarkGray
    exit 1
}

Bien 'Sin errores de activacion: Meta acepto la suscripcion.'

# ------------------------------------------------------- resumen
$base = Leer-Env 'WEBHOOK_URL'
if (-not $base) { $base = 'http://localhost:5678/' }
$base = $base.TrimEnd('/')
$urlPublica = "$base/webhook/$($webhooks[0].webhookPath)"

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host ' WHATSAPP CONECTADO' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "   Webhook registrado en Meta:  $urlPublica" -ForegroundColor White
Write-Host ''

if ($base -match '^http://(localhost|127\.0\.0\.1)') {
    Ojo 'PERO esa URL es LOCAL: los servidores de Meta no la alcanzan.'
    Write-Host ''
    Write-Host '    Levanta el tunel y vuelve a ejecutar este script:' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/tunel-rapido.ps1 -Detener   # por si quedo uno' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/tunel-rapido.ps1' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/activar-whatsapp.ps1 -Desactivar' -ForegroundColor DarkGray
    Write-Host '      powershell -File scripts/activar-whatsapp.ps1' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    El ciclo desactivar/activar es necesario: la callback_url que' -ForegroundColor DarkGray
    Write-Host '    n8n registro en Meta apunta a localhost y hay que reemplazarla.' -ForegroundColor DarkGray
}
elseif ($base -notmatch '^https://') {
    Ojo 'Meta exige HTTPS y esa URL no lo es.'
}
else {
    Write-Host '   NO hace falta configurar nada en el panel de Meta:' -ForegroundColor Green
    Write-Host '   n8n ya registro la callback_url y el verify_token por API.' -ForegroundColor Green
    Write-Host ''
    Write-Host '   Lo unico que queda:' -ForegroundColor Cyan
    Write-Host '     1. Meta > WhatsApp > API Setup > To > Manage phone number list'
    Write-Host '        Anade los celulares de prueba (hasta 5).'
    Write-Host '     2. Escribe "hola" desde uno de ellos.'
    Write-Host '     3. Mira la ejecucion en http://localhost:5678'
}

Write-Host ''
Write-Host '======================================================================'
Write-Host ''
Write-Host 'Para apagarlo:  powershell -File scripts/activar-whatsapp.ps1 -Desactivar' -ForegroundColor DarkGray
Write-Host '(tambien elimina la suscripcion en Meta)' -ForegroundColor DarkGray
