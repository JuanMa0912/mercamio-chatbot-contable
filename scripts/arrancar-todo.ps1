<#
.SYNOPSIS
  Deja el bot operativo tras un reinicio: pila arriba, tunel publicado y el
  webhook de Meta apuntando a la URL correcta.

.DESCRIPTION
  EL PROBLEMA QUE RESUELVE

  El tunel rapido de Cloudflare entrega un hostname ALEATORIO en cada arranque.
  El contenedor lleva `--restart unless-stopped`, asi que tras reiniciar el PC
  vuelve solo... con una URL distinta. El resultado es el peor estado posible:

    contenedor del tunel   arriba
    n8n                    healthy
    workflow               activo
    URL registrada en Meta apuntando a un host que ya no existe

  Todo verde y el bot mudo. Un proveedor escribe, Meta entrega a la URL vieja,
  nadie responde y no hay error en ningun sitio, porque desde dentro la
  instalacion parece correcta.

  Este script compara las tres cosas que tienen que coincidir —la URL viva del
  tunel, WEBHOOK_URL en .env y la callback_url registrada en Meta— y, si alguna
  se ha desincronizado, rehace el tunel y vuelve a registrar el webhook.

  ES SEGURO EJECUTARLO A MENUDO

  Si las tres coinciden no toca nada y termina en segundos. Por eso sirve tanto
  como tarea al iniciar sesion como en un intervalo de unos minutos, que cubre
  el caso de que Docker reinicie el tunel sin que nadie inicie sesion.

  ESTO NO ES UNA SOLUCION DEFINITIVA

  Un quick tunnel no esta pensado para produccion: Cloudflare puede cortarlo
  cuando quiera y no hay ningun acuerdo de servicio detras. Ademas quedan dos o
  tres minutos de silencio en cada arranque mientras se rehace el registro. Lo
  correcto es un tunel con nombre y dominio propio (docs/03, opcion A), o sacar
  el bot del PC de escritorio (docs/10). Esto es un parche que funciona, no el
  destino.

.PARAMETER SoloComprobar
  Informa del estado y de lo que haria, sin cambiar nada.

.PARAMETER Instalar
  Registra una tarea programada que ejecuta este script al iniciar sesion y
  cada 10 minutos.

.PARAMETER Desinstalar
  Elimina esa tarea programada.

.EXAMPLE
  powershell -File scripts/arrancar-todo.ps1
  powershell -File scripts/arrancar-todo.ps1 -SoloComprobar
  powershell -File scripts/arrancar-todo.ps1 -Instalar
#>
[CmdletBinding()]
param(
    [switch]$SoloComprobar,
    [switch]$Instalar,
    [switch]$Desinstalar,
    # Uso interno de la instalacion sin tarea programada: comprueba en bucle.
    [switch]$Vigilar
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

$CONTENEDOR = 'mercamio-tunel-rapido'
$ENV_RUTA   = Join-Path $raiz '.env'
$TAREA      = 'MERCAMIO chatbot - mantener tunel'
$LOG        = Join-Path $raiz 'logs\arrancar-todo.log'

# ------------------------------------------------------------------ salida
# Todo pasa por aqui para que la tarea programada, que corre sin ventana, deje
# rastro en disco. Sin log, un fallo a las 7 de la manana es invisible.
function Registrar {
    param([string]$Texto, [string]$Color = 'Gray')
    $linea = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto
    Write-Host $linea -ForegroundColor $Color
    try {
        $dir = Split-Path -Parent $LOG
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LOG -Value $linea -Encoding UTF8
    }
    catch { }
}
function Paso  { param([string]$t) Registrar "==> $t" 'Cyan' }
function Bien  { param([string]$t) Registrar "    [ok]    $t" 'Green' }
function Ojo   { param([string]$t) Registrar "    [aviso] $t" 'Yellow' }
function Falla { param([string]$t) Registrar "    [fallo] $t" 'Red' }

# Ver docs/01: redirigir stderr de un ejecutable nativo lanza NativeCommandError
# en PowerShell 5.1 y con ErrorActionPreference='Stop' mata el script.
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

function Leer-Env {
    param([string]$Clave)
    if (-not (Test-Path $ENV_RUTA)) { return '' }
    foreach ($linea in (Get-Content $ENV_RUTA -Encoding UTF8)) {
        if ($linea -match "^\s*$([regex]::Escape($Clave))\s*=\s*(.*)$") {
            return $matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return ''
}

# ------------------------------------------------------- tarea programada
if ($Instalar -or $Desinstalar) {
    # Se limpian las dos formas de instalacion, porque una maquina puede tener
    # la tarea y otra el acceso directo, y reinstalar sin limpiar dejaria dos
    # vigilantes compitiendo por rehacer el mismo tunel.
    $algoQuitado = $false
    if (Get-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false
        Registrar "Tarea '$TAREA' eliminada." 'Yellow'
        $algoQuitado = $true
    }
    $accesoViejo = Join-Path ([Environment]::GetFolderPath('Startup')) 'MERCAMIO chatbot - mantener tunel.lnk'
    if (Test-Path $accesoViejo) {
        Remove-Item $accesoViejo -Force
        Registrar 'Acceso directo de Inicio eliminado.' 'Yellow'
        $algoQuitado = $true
    }
    if ($Desinstalar) {
        if (-not $algoQuitado) { Registrar 'No habia nada instalado.' 'DarkGray' }
        exit 0
    }

    $script = Join-Path $PSScriptRoot 'arrancar-todo.ps1'
    $accion = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

    # Dos disparadores. El de inicio de sesion cubre el reinicio del PC; el
    # repetido cubre que Docker reinicie el tunel por su cuenta, sin que nadie
    # inicie sesion. El retraso de 2 minutos existe porque Docker Desktop tarda
    # en levantar el motor y sin el la primera ejecucion falla siempre.
    $t1 = New-ScheduledTaskTrigger -AtLogOn
    $t1.Delay = 'PT2M'
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
        -RepetitionInterval (New-TimeSpan -Minutes 10)

    $ajustes = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    # Register-ScheduledTask exige elevacion en muchos equipos con directivas
    # corporativas. Se intenta, y se COMPRUEBA que la tarea existe despues: el
    # cmdlet puede fallar con "Acceso denegado" sin cortar el script, y dar por
    # buena una instalacion que no ocurrio es peor que no instalar nada.
    $tareaCreada = $false
    try {
        Register-ScheduledTask -TaskName $TAREA -Action $accion -Trigger @($t1, $t2) `
            -Settings $ajustes -Description 'Rehace el tunel de Cloudflare y vuelve a registrar el webhook de WhatsApp cuando la URL cambia.' -ErrorAction Stop | Out-Null
    }
    catch { }
    $tareaCreada = [bool](Get-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue)

    if ($tareaCreada) {
        Registrar "Tarea '$TAREA' registrada: al iniciar sesion (+2 min) y cada 10 minutos." 'Green'
        Write-Host ''
        Write-Host "  Comprobarla:  Get-ScheduledTask -TaskName `"$TAREA`"" -ForegroundColor DarkGray
        Write-Host "  Registro:     $LOG" -ForegroundColor DarkGray
        Write-Host '  Quitarla:     powershell -File scripts/arrancar-todo.ps1 -Desinstalar' -ForegroundColor DarkGray
        exit 0
    }

    # Plan B, sin permisos de administrador: un acceso directo en la carpeta de
    # Inicio del usuario. Arranca al iniciar sesion y, como no hay programador
    # que lo repita, el propio script se queda vigilando en bucle (-Vigilar).
    Ojo 'No se pudo crear la tarea programada (hace falta elevacion).'
    Ojo 'Se instala en la carpeta de Inicio del usuario, que no requiere permisos.'

    $inicio = [Environment]::GetFolderPath('Startup')
    $acceso = Join-Path $inicio 'MERCAMIO chatbot - mantener tunel.lnk'
    $w = New-Object -ComObject WScript.Shell
    $lnk = $w.CreateShortcut($acceso)
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Vigilar"
    $lnk.WorkingDirectory = $raiz
    $lnk.Description = 'Rehace el tunel de Cloudflare y reregistra el webhook de WhatsApp cuando la URL cambia.'
    $lnk.Save()

    if (Test-Path $acceso) {
        Registrar 'Acceso directo creado en la carpeta de Inicio.' 'Green'
        Write-Host ''
        Write-Host "  Ubicacion:  $acceso" -ForegroundColor DarkGray
        Write-Host "  Registro:   $LOG" -ForegroundColor DarkGray
        Write-Host '  Quitarlo:   powershell -File scripts/arrancar-todo.ps1 -Desinstalar' -ForegroundColor DarkGray
        Write-Host ''
        Ojo 'Solo se activa al INICIAR SESION. Si quieres que funcione tambien'
        Ojo 'sin que nadie inicie sesion, instala la tarea desde un PowerShell'
        Ojo 'como administrador: la version con tarea programada es mejor.'
        exit 0
    }
    Falla 'Tampoco se pudo crear el acceso directo de Inicio.'
    exit 1
}

# ------------------------------------------------------------------ vigilar
# Modo bucle para la instalacion sin tarea programada. Hace la comprobacion,
# duerme y repite. Se relanza a si mismo como proceso normal, asi que basta
# cerrar la ventana (o cerrar sesion) para pararlo.
if ($Vigilar) {
    Registrar 'Vigilancia iniciada: se comprueba cada 10 minutos.' 'Cyan'
    while ($true) {
        try {
            & (Join-Path $PSScriptRoot 'arrancar-todo.ps1')
        }
        catch {
            Registrar "Error en la comprobacion: $($_.Exception.Message)" 'Red'
        }
        Start-Sleep -Seconds 600
    }
}

# ------------------------------------------------------------ 1. Docker
Paso 'Esperando a que Docker responda'
$dockerListo = $false
foreach ($i in 1..30) {
    if ((Invocar-Nativo { docker info }) -eq 0) { $dockerListo = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $dockerListo) {
    Falla 'Docker no respondio en 5 minutos. Esta arrancado Docker Desktop?'
    exit 1
}
Bien 'Docker responde.'

# --------------------------------------------------------------- 2. pila
Paso 'Levantando n8n y PostgreSQL'
if (-not $SoloComprobar) {
    if ((Invocar-Nativo { docker compose up -d }) -ne 0) {
        Falla 'docker compose up fallo. Revisa: docker compose logs'
        exit 1
    }
}
$n8nListo = $false
foreach ($i in 1..40) {
    try {
        # 127.0.0.1 y NO localhost: en Windows 11 localhost resuelve primero a
        # ::1 e Invoke-RestMethod no hace el fallback a IPv4 que si hace curl.
        if ((Invoke-RestMethod -Uri 'http://127.0.0.1:5678/healthz' -TimeoutSec 5).status -eq 'ok') {
            $n8nListo = $true; break
        }
    }
    catch { }
    Start-Sleep -Seconds 3
}
if (-not $n8nListo) { Falla 'n8n no respondio en /healthz.'; exit 1 }
Bien 'n8n responde.'

# ------------------------------------------------- 3. las tres URL cuadran?
Paso 'Comparando la URL del tunel, .env y lo registrado en Meta'

$urlTunel = ''
$hayContenedor = (Salida-Nativa { docker ps --filter "name=$CONTENEDOR" --format '{{.Names}}' }).Trim()
if ($hayContenedor) {
    $logs = Salida-Nativa { docker logs $CONTENEDOR 2>&1 }
    # Los logs acumulan la URL de cada arranque del contenedor; la ultima
    # coincidencia es la vigente. Con Match (la primera) se leeria una muerta.
    $m = [regex]::Matches($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($m.Count -gt 0) { $urlTunel = $m[$m.Count - 1].Value }
}
$urlEnv = (Leer-Env 'WEBHOOK_URL').TrimEnd('/')

Registrar ("    tunel vivo      : {0}" -f $(if ($urlTunel) { $urlTunel } else { '(no hay tunel)' }))
Registrar ("    WEBHOOK_URL     : {0}" -f $(if ($urlEnv) { $urlEnv } else { '(vacio)' }))

# La callback_url de Meta se consulta con un token de app (app_id|app_secret),
# no con el token de usuario: asi funciona aunque el token del bot expirara.
$urlMeta = ''
$appId = Leer-Env 'WHATSAPP_APP_ID'
$appSecret = Leer-Env 'WHATSAPP_APP_SECRET'
if ($appId -and $appSecret) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -TimeoutSec 20 -Uri ("https://graph.facebook.com/v23.0/$appId/subscriptions?access_token=" + [Uri]::EscapeDataString("$appId|$appSecret"))
        $wa = @($r.data | Where-Object { $_.object -eq 'whatsapp_business_account' })
        if ($wa.Count -gt 0) { $urlMeta = "$($wa[0].callback_url)" }
    }
    catch {
        Ojo "No se pudo consultar Meta: $($_.Exception.Message)"
    }
}
Registrar ("    callback en Meta: {0}" -f $(if ($urlMeta) { $urlMeta } else { '(ninguna)' }))

$coinciden = $urlTunel -and $urlEnv -and $urlMeta -and
             ($urlEnv -eq $urlTunel) -and
             $urlMeta.StartsWith($urlTunel, [StringComparison]::OrdinalIgnoreCase)

# Que las tres cadenas coincidan NO significa que el bot este accesible.
#
# Cloudflare puede matar un quick tunnel cuando quiera, y cuando lo hace el
# contenedor sigue "Up" reintentando contra un tunel que ya no existe:
#
#   ERR Register tunnel error from server side error="Unauthorized: Tunnel not found"
#
# La URL sigue siendo la misma en el contenedor, en .env y en Meta, asi que una
# comprobacion de consistencia la da por buena. Pero el DNS ya no resuelve y
# Meta no puede entregar nada. Paso de verdad tras tres horas de tunel.
#
# La unica comprobacion que vale es pedir la URL desde fuera y ver si responde.
$alcanzable = $false
if ($urlTunel) {
    # PowerShell 5.1 negocia TLS 1.0/1.1 segun el sistema y Cloudflare corta.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Tres intentos, vaciando la cache DNS del cliente antes de cada uno.
    #
    # Si alguien consulto el hostname justo despues de crearlo, Windows tiene
    # cacheada una respuesta NEGATIVA y este proceso cree que el dominio no
    # existe aunque el tunel funcione. Sin el vaciado, esa cache basta para que
    # el vigilante concluya "no responde", rehaga el tunel, envenene la cache de
    # nuevo con la URL nueva y entre en un bucle: cada diez minutos una URL
    # distinta y un reregistro mas en Meta. Es peor que no vigilar nada.
    #
    # Un fallo solo cuenta como tal si se repite con la cache limpia.
    foreach ($intento in 1..3) {
        try { Clear-DnsClientCache } catch { }
        try {
            $resp = Invoke-WebRequest -Uri "$urlTunel/healthz" -TimeoutSec 25 -UseBasicParsing
            if ($resp.StatusCode -eq 200) { $alcanzable = $true; break }
        }
        catch { }
        if ($intento -lt 3) { Start-Sleep -Seconds 5 }
    }
    Registrar ("    responde desde internet: {0}" -f $(if ($alcanzable) { 'si' } else { 'NO' }))
}

if ($coinciden -and $alcanzable) {
    Bien 'Las tres coinciden y la URL responde desde internet.'
    exit 0
}

if (-not $urlTunel)                { Ojo 'No hay tunel levantado.' }
elseif ($urlEnv -ne $urlTunel)     { Ojo 'El tunel cambio de URL y .env se quedo con la anterior.' }
elseif (-not $urlMeta)             { Ojo 'Meta no tiene ninguna suscripcion registrada.' }
elseif (-not $urlMeta.StartsWith($urlTunel, [StringComparison]::OrdinalIgnoreCase)) {
    Ojo 'Meta apunta a una URL distinta de la del tunel.'
}
else {
    Ojo 'Las tres URL coinciden pero la direccion NO responde desde internet.'
    Ojo 'Cloudflare ha tumbado el tunel; el contenedor sigue arriba reintentando'
    Ojo 'contra un tunel que ya no existe. Se rehace desde cero.'
}

if ($SoloComprobar) {
    Registrar ''
    Registrar 'Haria: rehacer el tunel y volver a registrar el webhook.' 'Yellow'
    Registrar 'Ejecuta el script sin -SoloComprobar para aplicarlo.' 'DarkGray'
    exit 2
}

# ------------------------------------------------------- 4. rehacer tunel
Paso 'Rehaciendo el tunel'
& (Join-Path $PSScriptRoot 'tunel-rapido.ps1')
if ($LASTEXITCODE -ne 0) { Falla "tunel-rapido.ps1 devolvio $LASTEXITCODE."; exit 1 }

# -------------------------------------------- 5. reregistrar en Meta
# activar-whatsapp.ps1 desactiva y vuelve a activar el workflow, y es al
# activarse cuando el WhatsApp Trigger registra la callback_url en Meta. No hay
# forma de reregistrar sin pasar por ahi.
Paso 'Volviendo a registrar el webhook en Meta'
& (Join-Path $PSScriptRoot 'activar-whatsapp.ps1')
if ($LASTEXITCODE -ne 0) { Falla "activar-whatsapp.ps1 devolvio $LASTEXITCODE."; exit 1 }

# --------------------------------------------------------- 6. confirmar
Paso 'Confirmando'
$urlEnv2 = (Leer-Env 'WEBHOOK_URL').TrimEnd('/')
$urlMeta2 = ''
if ($appId -and $appSecret) {
    try {
        $r2 = Invoke-RestMethod -TimeoutSec 20 -Uri ("https://graph.facebook.com/v23.0/$appId/subscriptions?access_token=" + [Uri]::EscapeDataString("$appId|$appSecret"))
        $wa2 = @($r2.data | Where-Object { $_.object -eq 'whatsapp_business_account' })
        if ($wa2.Count -gt 0) { $urlMeta2 = "$($wa2[0].callback_url)" }
    }
    catch { }
}
if ($urlMeta2 -and $urlEnv2 -and $urlMeta2.StartsWith($urlEnv2, [StringComparison]::OrdinalIgnoreCase)) {
    Bien "Meta apunta a $urlEnv2"
    Registrar ''
    Registrar 'El bot esta operativo.' 'Green'
    exit 0
}
Falla 'Meta no quedo apuntando a la URL nueva.'
Registrar "    .env : $urlEnv2"
Registrar "    Meta : $urlMeta2"
Falla 'Diagnostica con: powershell -File scripts/verificar-whatsapp.ps1'
exit 1
