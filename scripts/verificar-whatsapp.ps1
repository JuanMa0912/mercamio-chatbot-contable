<#
.SYNOPSIS
  Diagnostica el token y los numeros de WhatsApp Cloud API contra la Graph API.

.DESCRIPTION
  Responde, sin adivinar, a las preguntas que bloquean la conexion con n8n:

    - El token es valido? De que tipo? Cuando caduca?
    - Tiene los permisos whatsapp_business_messaging y _management?
    - Que numeros tiene la cuenta y en que estado esta cada uno?
    - El nombre para mostrar esta aprobado o pendiente?
    - Cual es el Phone Number ID que hay que darle a n8n?

  No toca n8n ni guarda nada: solo consulta la Graph API de Meta. Con -EnviarA
  manda un mensaje de texto real para cerrar la prueba de punta a punta.

  El token se lee, en este orden:
    1. el parametro -Token
    2. la variable WHATSAPP_TOKEN de .env
    3. se pide por teclado (no se guarda)

.PARAMETER Token
  Token de acceso. Mejor no pasarlo por linea de comandos: queda en el
  historial de PowerShell. Usa .env o deja que lo pida.

.PARAMETER WabaId
  WhatsApp Business Account ID. Si se omite, se lee de WHATSAPP_WABA_ID en .env
  y, si tampoco esta, se intenta descubrir a partir del token.

.PARAMETER EnviarA
  Numero de destino en formato internacional sin signos (ej. 573001112233).
  Manda un mensaje de prueba. Con el numero de pruebas de Meta, el destino
  tiene que estar en la lista de destinatarios permitidos.

.PARAMETER Version
  Version de la Graph API. Si Meta responde que la version no existe, sube el
  numero: las versiones se retiran cada ~2 anos.

.EXAMPLE
  powershell -File scripts/verificar-whatsapp.ps1
  powershell -File scripts/verificar-whatsapp.ps1 -EnviarA 573001112233
#>
[CmdletBinding()]
param(
    [string]$Token = '',
    [string]$WabaId = '',
    [string]$EnviarA = '',
    [string]$Version = 'v23.0'
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

# Windows PowerShell 5.1 negocia TLS 1.0/1.1 segun la configuracion del
# sistema. La Graph API exige TLS 1.2 o superior y cierra la conexion, lo que
# produce un "La conexion subyacente se cerro" que no dice nada del problema
# real. Hay que forzarlo antes de la primera peticion.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$GRAFO = "https://graph.facebook.com/$Version"

function Titulo { param([string]$t) Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Bien   { param([string]$t) Write-Host "   [ok]    $t" -ForegroundColor Green }
function Ojo    { param([string]$t) Write-Host "   [aviso] $t" -ForegroundColor Yellow }
function Mal    { param([string]$t) Write-Host "   [fallo] $t" -ForegroundColor Red }
function Dato   { param([string]$k, [string]$v) Write-Host ("   {0,-22} {1}" -f $k, $v) }

# ----------------------------------------------------------------- .env
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

if (-not $Token)  { $Token  = Leer-Env 'WHATSAPP_TOKEN' }
if (-not $WabaId) { $WabaId = Leer-Env 'WHATSAPP_WABA_ID' }
$phoneIdEnv = Leer-Env 'WHATSAPP_PHONE_NUMBER_ID'

if (-not $Token) {
    Write-Host ''
    Write-Host 'No hay token. Ponlo en .env como WHATSAPP_TOKEN o pegalo aqui.' -ForegroundColor Yellow
    Write-Host 'Donde encontrarlo: docs/09-registrar-numero-whatsapp.md' -ForegroundColor DarkGray
    $seguro = Read-Host 'Token de acceso' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
    try { $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $Token) { Mal 'Sin token no hay nada que comprobar.'; exit 1 }

# ------------------------------------------------------------- peticiones
# Devuelve un objeto con Ok / Datos / Error para poder informar del error de
# Meta en lugar de dejar escapar una excepcion cruda.
function Llamar {
    param([string]$Ruta, [hashtable]$Query = @{}, [string]$Metodo = 'GET', $Cuerpo = $null)

    $partes = @()
    foreach ($k in $Query.Keys) {
        $partes += ($k + '=' + [Uri]::EscapeDataString([string]$Query[$k]))
    }
    $url = $GRAFO + $Ruta
    if ($partes.Count -gt 0) { $url = $url + '?' + ($partes -join '&') }

    $cab = @{ Authorization = 'Bearer ' + $Token }
    try {
        if ($Metodo -eq 'POST') {
            $r = Invoke-RestMethod -Uri $url -Method Post -Headers $cab `
                 -ContentType 'application/json' -Body ($Cuerpo | ConvertTo-Json -Depth 6) -TimeoutSec 30
        }
        else {
            $r = Invoke-RestMethod -Uri $url -Method Get -Headers $cab -TimeoutSec 30
        }
        return [pscustomobject]@{ Ok = $true; Datos = $r; Error = $null }
    }
    catch {
        $err = $_
        $detalle = $err.Exception.Message   # generico: "(401) No autorizado"

        # Meta explica el motivo real en el CUERPO de la respuesta, no en el
        # status. Sin esto, un token mal copiado y un permiso ausente producen
        # exactamente el mismo mensaje inutil.
        #
        # En Windows PowerShell 5.1 hay que leerlo de $_.ErrorDetails.Message:
        # Invoke-RestMethod YA consumio el stream, asi que
        # $_.Exception.Response.GetResponseStream() devuelve vacio. Se intenta
        # el stream solo como reserva para otras versiones de PowerShell.
        $crudo = ''
        if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
            $crudo = $err.ErrorDetails.Message
        }
        elseif ($err.Exception.Response) {
            try {
                $lector = New-Object IO.StreamReader($err.Exception.Response.GetResponseStream())
                $crudo = $lector.ReadToEnd()
                $lector.Close()
            }
            catch { }
        }

        if ($crudo) {
            try {
                $j = $crudo | ConvertFrom-Json
                if ($j.error) {
                    $detalle = $j.error.message
                    if ($j.error.code) { $detalle = "[#$($j.error.code)] $detalle" }
                    if ($j.error.error_subcode) { $detalle = $detalle + " (subcode $($j.error.error_subcode))" }
                    if ($j.error.error_user_msg) { $detalle = $detalle + ' | ' + $j.error.error_user_msg }
                }
            }
            catch {
                # No era JSON: mejor el cuerpo recortado que el mensaje generico.
                $detalle = $detalle + ' | ' + $crudo.Substring(0, [Math]::Min(200, $crudo.Length))
            }
        }
        return [pscustomobject]@{ Ok = $false; Datos = $null; Error = $detalle }
    }
}

Write-Host ''
Write-Host '======================================================================'
Write-Host ' Diagnostico de WhatsApp Cloud API'
Write-Host " Graph API $Version"
Write-Host '======================================================================'

$problemas = @()

# ------------------------------------------------------- 1. el token sirve?
Titulo '1. Token'

$dbg = Llamar '/debug_token' @{ input_token = $Token }
if ($dbg.Ok -and $dbg.Datos.data) {
    $d = $dbg.Datos.data
    Dato 'valido' $(if ($d.is_valid) { 'si' } else { 'NO' })
    Dato 'tipo' "$($d.type)"
    Dato 'app_id' "$($d.app_id)"
    if ($d.application) { Dato 'app' "$($d.application)" }

    if ($d.expires_at -and $d.expires_at -ne 0) {
        $caduca = [DateTimeOffset]::FromUnixTimeSeconds([int64]$d.expires_at).LocalDateTime
        $horas = [math]::Round(($caduca - (Get-Date)).TotalHours, 1)
        Dato 'caduca' "$caduca  (en $horas h)"
        if ($horas -lt 168) {
            Ojo 'Token TEMPORAL. Va a caducar y el bot dejara de responder sin aviso claro.'
            Ojo 'Crea un token permanente con un Usuario del sistema (docs/09, paso 3).'
            $problemas += 'token temporal'
        }
    }
    else {
        Bien 'Token permanente (sin fecha de caducidad).'
    }

    if (-not $d.is_valid) {
        Mal 'Meta lo marca como invalido. Genera otro.'
        $problemas += 'token invalido'
    }

    $ambitos = @($d.scopes)
    Dato 'permisos' $(if ($ambitos.Count) { $ambitos -join ', ' } else { '(ninguno)' })
    foreach ($nec in @('whatsapp_business_messaging', 'whatsapp_business_management')) {
        if ($ambitos -contains $nec) { Bien "permiso $nec" }
        else {
            Mal "FALTA el permiso $nec"
            $problemas += "falta $nec"
        }
    }
}
else {
    # debug_token puede requerir token de app. Si falla, al menos se comprueba
    # que el token responde a algo.
    Ojo "No se pudo inspeccionar el token: $($dbg.Error)"
    $yo = Llamar '/me' @{ fields = 'id,name' }
    if ($yo.Ok) {
        Bien "El token responde. Identidad: $($yo.Datos.name) ($($yo.Datos.id))"
        Ojo 'No se pudieron leer permisos ni caducidad. Revisalos en el panel de Meta.'
    }
    else {
        Mal "El token no sirve: $($yo.Error)"
        Write-Host ''
        Write-Host '   Causas mas frecuentes:' -ForegroundColor DarkGray
        Write-Host '     - Es el token temporal y ya pasaron 24 h.' -ForegroundColor DarkGray
        Write-Host '     - Se copio incompleto (son varios cientos de caracteres).' -ForegroundColor DarkGray
        Write-Host "     - La version $Version de la Graph API ya no existe: prueba -Version v24.0" -ForegroundColor DarkGray
        exit 1
    }
}

# --------------------------------------------- 2. que cuenta de WhatsApp?
Titulo '2. Cuenta de WhatsApp Business (WABA)'

if (-not $WabaId) {
    $negocios = Llamar '/me/businesses' @{ fields = 'id,name' }
    if ($negocios.Ok -and $negocios.Datos.data) {
        foreach ($n in $negocios.Datos.data) {
            Dato 'negocio' "$($n.name)  ($($n.id))"
            $wabas = Llamar "/$($n.id)/owned_whatsapp_business_accounts" @{ fields = 'id,name' }
            if ($wabas.Ok -and $wabas.Datos.data) {
                foreach ($w in $wabas.Datos.data) {
                    Dato '  WABA' "$($w.name)  ($($w.id))"
                    if (-not $WabaId) { $WabaId = $w.id }
                }
            }
        }
    }
    if (-not $WabaId) {
        Ojo 'No se pudo descubrir la WABA automaticamente.'
        Ojo 'Copiala del panel (WhatsApp > API Setup) y ponla en .env como WHATSAPP_WABA_ID.'
    }
    else {
        Bien "Se usara la WABA $WabaId"
    }
}
else {
    Dato 'WABA (de .env)' $WabaId
}

# ----------------------------------------------------------- 3. los numeros
Titulo '3. Numeros de telefono'

$idsEncontrados = @()
if ($WabaId) {
    $campos = 'id,display_phone_number,verified_name,code_verification_status,quality_rating,platform_type,name_status,is_official_business_account'
    $nums = Llamar "/$WabaId/phone_numbers" @{ fields = $campos }
    if ($nums.Ok -and $nums.Datos.data) {
        $i = 0
        foreach ($p in $nums.Datos.data) {
            $i += 1
            Write-Host ''
            Write-Host "   --- numero $i ---" -ForegroundColor White
            Dato 'telefono' "$($p.display_phone_number)"
            Dato 'Phone Number ID' "$($p.id)"
            Dato 'nombre visible' "$($p.verified_name)"
            Dato 'estado del nombre' "$($p.name_status)"
            Dato 'verificacion' "$($p.code_verification_status)"
            Dato 'calidad' "$($p.quality_rating)"
            Dato 'plataforma' "$($p.platform_type)"
            $idsEncontrados += $p.id

            if ("$($p.code_verification_status)" -ne 'VERIFIED') {
                Mal 'El numero NO esta verificado: no puede enviar ni recibir.'
                Mal 'Completa la verificacion por SMS o llamada (docs/09, paso 5).'
                $problemas += "numero $($p.display_phone_number) sin verificar"
            }
            else {
                Bien 'Numero verificado.'
            }

            if ("$($p.name_status)" -eq 'PENDING_REVIEW') {
                Ojo 'El nombre visible esta en revision por Meta. El bot funciona igual;'
                Ojo 'el proveedor vera el numero en vez del nombre comercial.'
            }
            elseif ("$($p.name_status)" -eq 'DECLINED') {
                Ojo 'Meta RECHAZO el nombre visible. Debe parecerse al nombre real del negocio.'
            }

            if ("$($p.platform_type)" -eq 'ON_PREMISE') {
                Ojo 'Este numero esta en la API On-Premise, no en Cloud API.'
                Ojo 'n8n usa Cloud API: hay que migrarlo.'
                $problemas += 'numero en On-Premise'
            }
        }
    }
    elseif ($nums.Ok) {
        Ojo 'La WABA no tiene ningun numero todavia. Ver docs/09, paso 4.'
        $problemas += 'sin numeros'
    }
    else {
        Mal "No se pudieron leer los numeros: $($nums.Error)"
        $problemas += 'lectura de numeros fallida'
    }
}

if ($phoneIdEnv) {
    Write-Host ''
    Dato 'PHONE_NUMBER_ID .env' $phoneIdEnv
    if ($idsEncontrados.Count -and ($idsEncontrados -notcontains $phoneIdEnv)) {
        Ojo 'Ese ID no aparece entre los numeros de la WABA. Puede estar desactualizado.'
    }
}

# --------------------------------------------------- 4. envio de prueba
if ($EnviarA) {
    Titulo '4. Envio de prueba'

    $idEnvio = $phoneIdEnv
    if (-not $idEnvio -and $idsEncontrados.Count -eq 1) { $idEnvio = $idsEncontrados[0] }
    if (-not $idEnvio) {
        Mal 'Hay varios numeros (o ninguno). Define WHATSAPP_PHONE_NUMBER_ID en .env.'
    }
    else {
        $destino = ($EnviarA -replace '\D', '')
        Dato 'desde (ID)' $idEnvio
        Dato 'hacia' $destino

        $cuerpo = @{
            messaging_product = 'whatsapp'
            to                = $destino
            type              = 'text'
            text              = @{ body = 'Prueba del ChatBOT contable de MERCAMIO. Si recibes esto, el envio funciona.' }
        }
        $env1 = Llamar "/$idEnvio/messages" @{} 'POST' $cuerpo
        if ($env1.Ok) {
            Bien "Mensaje aceptado por Meta. id: $($env1.Datos.messages[0].id)"
            Ojo 'Aceptado no es entregado: confirma que llego al telefono.'
        }
        else {
            Mal "Meta rechazo el envio: $($env1.Error)"
            Write-Host ''
            Write-Host '   Traduccion de los errores mas comunes:' -ForegroundColor DarkGray
            Write-Host '     #131030  el destino no esta en la lista de permitidos (numero de pruebas)' -ForegroundColor DarkGray
            Write-Host '     #131047  pasaron 24 h desde el ultimo mensaje del usuario: hace falta plantilla' -ForegroundColor DarkGray
            Write-Host '     #131026  el destino no tiene WhatsApp, o el formato del numero es incorrecto' -ForegroundColor DarkGray
            Write-Host '     #133010  el numero no esta registrado en Cloud API' -ForegroundColor DarkGray
            Write-Host '     #190     token caducado o revocado' -ForegroundColor DarkGray
            $problemas += 'envio rechazado'
        }
    }
}

# ------------------------------------------------------------- veredicto
Write-Host ''
Write-Host '======================================================================'
if ($problemas.Count -eq 0) {
    Write-Host ' TODO EN ORDEN' -ForegroundColor Green
    Write-Host ''
    Write-Host ' Siguiente paso: crear las credenciales en n8n con estos datos.'
    Write-Host ' Ver docs/04-credenciales.md'
}
else {
    Write-Host ' HAY QUE RESOLVER:' -ForegroundColor Yellow
    foreach ($p in ($problemas | Select-Object -Unique)) { Write-Host "   - $p" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ' Paso a paso: docs/09-registrar-numero-whatsapp.md'
}
Write-Host '======================================================================'
Write-Host ''
