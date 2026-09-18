<#
.SYNOPSIS
  Publica n8n en una URL HTTPS temporal para que Meta pueda entregar el webhook.

.DESCRIPTION
  Usa el "quick tunnel" de Cloudflare: NO necesita cuenta, ni dominio, ni token.
  Levanta un contenedor cloudflared en la red de compose, obtiene una URL
  https://algo.trycloudflare.com, la escribe en WEBHOOK_URL y recrea n8n.

  LIMITE IMPORTANTE: la URL CAMBIA cada vez que se levanta el tunel. Cada cambio
  obliga a volver a registrar el webhook en Meta. Sirve para una sesion de
  pruebas, no para dejarlo puesto. Para algo permanente hace falta un tunel con
  nombre y dominio propio: docs/03-webhook-whatsapp-tunel.md.

  SEGURIDAD: esto expone tu n8n a internet, incluido el formulario de login.
  El script se niega a arrancar si no existe la cuenta de propietario, porque
  con la instancia sin configurar el primero que encuentre la URL se convierte
  en administrador.

.PARAMETER Detener
  Para el tunel y devuelve WEBHOOK_URL a http://localhost:5678/.

.PARAMETER Estado
  Muestra si hay tunel levantado y con que URL.

.EXAMPLE
  powershell -File scripts/tunel-rapido.ps1
  powershell -File scripts/tunel-rapido.ps1 -Estado
  powershell -File scripts/tunel-rapido.ps1 -Detener
#>
[CmdletBinding()]
param(
    [switch]$Detener,
    [switch]$Estado
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

$CONTENEDOR = 'mercamio-tunel-rapido'
$RED = 'mercamio-chatbot-contable_default'
$ENV_RUTA = Join-Path $raiz '.env'

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

# Reescribe una clave de .env conservando el resto del archivo intacto.
function Fijar-Env {
    param([string]$Clave, [string]$Valor)
    $lineas = Get-Content $ENV_RUTA -Encoding UTF8
    $encontrada = $false
    $nuevas = foreach ($l in $lineas) {
        if ($l -match "^\s*$([regex]::Escape($Clave))\s*=") { $encontrada = $true; "$Clave=$Valor" }
        else { $l }
    }
    if (-not $encontrada) { $nuevas = $nuevas + "$Clave=$Valor" }
    # UTF8 sin BOM: docker compose no interpreta el BOM y la primera clave del
    # archivo se leeria con caracteres invisibles delante.
    [IO.File]::WriteAllLines($ENV_RUTA, $nuevas, (New-Object Text.UTF8Encoding($false)))
}

function Esperar-n8n {
    foreach ($i in 1..40) {
        Start-Sleep -Seconds 3
        try {
            if ((Invoke-RestMethod -Uri 'http://127.0.0.1:5678/healthz' -TimeoutSec 5).status -eq 'ok') { return $true }
        }
        catch { }
    }
    $salud = (docker inspect --format '{{.State.Health.Status}}' mercamio-n8n 2>$null) -join ''
    return ($salud.Trim() -eq 'healthy')
}

function Url-Del-Tunel {
    $logs = Salida-Nativa { docker logs $CONTENEDOR 2>&1 }
    $m = [regex]::Match($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($m.Success) { return $m.Value }
    return ''
}

# ------------------------------------------------------------------ estado
if ($Estado) {
    $existe = (Salida-Nativa { docker ps -a --filter "name=$CONTENEDOR" --format '{{.Names}}|{{.Status}}' })
    if (-not $existe) { Write-Host 'No hay tunel levantado.' -ForegroundColor DarkGray; exit 0 }
    Write-Host "Contenedor: $existe"
    $u = Url-Del-Tunel
    if ($u) { Write-Host "URL: $u" -ForegroundColor Green }
    Write-Host "WEBHOOK_URL en .env: $((Get-Content $ENV_RUTA | Select-String '^WEBHOOK_URL=') -join '')"
    exit 0
}

# ----------------------------------------------------------------- detener
if ($Detener) {
    Paso 'Parando el tunel'
    Invocar-Nativo { docker rm -f $CONTENEDOR } | Out-Null
    Bien 'Contenedor eliminado.'

    Paso 'Devolviendo la configuracion a local'
    Fijar-Env 'WEBHOOK_URL' 'http://localhost:5678/'
    Fijar-Env 'N8N_HOST' 'localhost'
    Fijar-Env 'N8N_PROTOCOL' 'http'
    Fijar-Env 'N8N_SECURE_COOKIE' 'false'
    Fijar-Env 'N8N_PROXY_HOPS' '0'

    Invocar-Nativo { docker compose up -d n8n } | Out-Null
    if (Esperar-n8n) { Bien 'n8n de vuelta en http://localhost:5678' }
    else { Falla 'n8n no volvio. Revisa: docker compose logs n8n'; exit 1 }

    Ojo 'El webhook registrado en Meta ya no funciona: apunta a una URL muerta.'
    exit 0
}

# ------------------------------------------------- 1. guarda de seguridad
Paso 'Comprobando que la instancia esta protegida'

$previo = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # OJO con las comillas. `user` es palabra reservada en PostgreSQL, asi que
    # la tabla EXIGE ir entre comillas dobles. Pero PowerShell 5.1 se COME las
    # comillas dobles al pasar un argumento a un ejecutable nativo: escribir
    # ""user"" aqui hace que psql reciba `from user` a secas y responda
    # "column email does not exist".
    #
    # Eso convertia esta comprobacion de seguridad en un bloqueo permanente:
    # decia "no hay cuenta de propietario" aunque la hubiera, y el tunel no
    # levantaba nunca. El riesgo real es que alguien lo diagnostique como un
    # falso positivo y quite la comprobacion entera.
    #
    # La barra invertida es la forma de pasar una comilla doble LITERAL a un
    # nativo desde PowerShell. Verificado: con \" devuelve el conteo correcto.
    $sqlDuenos = 'select count(*) from \"user\" where email is not null and password is not null;'
    $duenos = docker compose exec -T postgres psql -U n8n -d n8n -t -A -c $sqlDuenos
}
finally { $ErrorActionPreference = $previo }
$n = 0
[int]::TryParse((($duenos -join '').Trim()), [ref]$n) | Out-Null

if ($n -lt 1) {
    Falla 'No hay cuenta de propietario en n8n.'
    Write-Host ''
    Write-Host '    Abrir un tunel ahora seria grave: la instancia sin configurar deja' -ForegroundColor Red
    Write-Host '    que CUALQUIERA que encuentre la URL cree la cuenta de administrador' -ForegroundColor Red
    Write-Host '    y se quede con tus workflows y credenciales.' -ForegroundColor Red
    Write-Host ''
    Write-Host '    Crea la cuenta primero en http://localhost:5678' -ForegroundColor DarkGray
    exit 1
}
Bien "Hay $n cuenta(s) con contrasena."
Ojo 'Recuerda: el tunel expone el login de n8n a internet. Si la contrasena es'
Ojo 'debil (algo derivado de "mercamio", por ejemplo), cambiala antes de seguir.'

# ------------------------------------------------------- 2. levantar tunel
Paso 'Levantando el tunel de Cloudflare'

Invocar-Nativo { docker rm -f $CONTENEDOR } | Out-Null

$codigo = Invocar-Nativo {
    docker run -d --name $CONTENEDOR --network $RED --restart unless-stopped `
        cloudflare/cloudflared:latest tunnel --no-autoupdate --url http://n8n:5678
}
if ($codigo -ne 0) {
    Falla "No se pudo arrancar cloudflared (codigo $codigo)."
    Write-Host "    Si la red no existe, arranca la pila: docker compose up -d" -ForegroundColor DarkGray
    exit 1
}
Bien 'Contenedor cloudflared arrancado.'

Paso 'Esperando la URL publica'
$url = ''
foreach ($i in 1..30) {
    Start-Sleep -Seconds 2
    $url = Url-Del-Tunel
    if ($url) { break }
}
if (-not $url) {
    Falla 'Cloudflare no entrego una URL en 60 segundos.'
    Write-Host "    Revisa: docker logs $CONTENEDOR" -ForegroundColor DarkGray
    exit 1
}
Bien "URL: $url"

# --------------------------------------------------- 3. reconfigurar n8n
Paso 'Actualizando .env y recreando n8n'

$host_ = ([Uri]$url).Host
Fijar-Env 'WEBHOOK_URL' ($url + '/')
Fijar-Env 'N8N_HOST' $host_
Fijar-Env 'N8N_PROTOCOL' 'https'
# En HTTPS la cookie de sesion debe ir marcada como Secure.
Fijar-Env 'N8N_SECURE_COOKIE' 'true'
# Sin esto n8n toma la IP de cloudflared como IP del cliente.
Fijar-Env 'N8N_PROXY_HOPS' '1'

# `up -d` y no `restart`: restart NO relee .env, las variables se fijan al
# crear el contenedor.
Invocar-Nativo { docker compose up -d n8n } | Out-Null
if (-not (Esperar-n8n)) {
    Falla 'n8n no volvio a responder. Revisa: docker compose logs n8n'
    exit 1
}
Bien 'n8n recreado con la URL publica.'

# ------------------------------------------------------- 4. comprobar
Paso 'Comprobando el acceso desde fuera'
$ok = $false
foreach ($i in 1..10) {
    try {
        if ((Invoke-RestMethod -Uri "$url/healthz" -TimeoutSec 10).status -eq 'ok') { $ok = $true; break }
    }
    catch { Start-Sleep -Seconds 3 }
}
if ($ok) { Bien "$url/healthz responde desde internet." }
else { Ojo 'El healthz publico aun no responde. Cloudflare tarda unos segundos mas.' }

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host " URL PUBLICA:  $url" -ForegroundColor White
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Siguiente paso:' -ForegroundColor Cyan
Write-Host '  powershell -File scripts/activar-whatsapp.ps1'
Write-Host '     (activa el workflow y te da la URL exacta del webhook para Meta)'
Write-Host ''
Write-Host 'Al terminar:' -ForegroundColor DarkGray
Write-Host '  powershell -File scripts/tunel-rapido.ps1 -Detener' -ForegroundColor DarkGray
Write-Host ''
Ojo 'La URL cambia en cada arranque del tunel. Si lo paras y lo vuelves a'
Ojo 'levantar, hay que registrar el webhook en Meta otra vez. Para algo estable,'
Ojo 'usa un tunel con nombre: docs/03-webhook-whatsapp-tunel.md'
