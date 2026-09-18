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
$tokenInservible = $false

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

    # Con varias apps en la cuenta, "el token" no identifica nada por si solo.
    # Comparar este app_id con el WHATSAPP_APP_ID de .env evita el error de
    # mezclar el token de una app con el App Secret de otra: la activacion
    # fallaria y la firma de los mensajes nunca cuadraria.
    $appIdEnv = Leer-Env 'WHATSAPP_APP_ID'
    if ($appIdEnv) {
        if ("$($d.app_id)" -eq $appIdEnv) {
            Bien "El token pertenece a la misma app que WHATSAPP_APP_ID ($appIdEnv)."
        }
        else {
            Mal "DESAJUSTE: el token es de la app $($d.app_id), pero .env dice $appIdEnv."
            Mal 'Token y App ID/Secret deben ser de la MISMA app de Facebook.'
            $problemas += 'token y APP_ID de apps distintas'
        }
    }
    else {
        Ojo "El token pertenece a la app $($d.app_id). Ese es el App ID que va en .env."
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

        # El subcode 463 es "sesion expirada". Es el fallo mas frecuente con
        # diferencia: el token del boton "Generar token" de API Setup caduca a
        # una hora fija, no 24 h despues de generarlo. Merece su propio mensaje
        # en lugar de una lista generica de causas posibles.
        if ("$($yo.Error)" -match 'subcode 463|[Ss]ession has expired') {
            Mal 'TOKEN CADUCADO. Es el temporal de "API Setup", no uno permanente.'
            Write-Host ''
            Write-Host '   Ese boton da un token que caduca a una hora fija. Regenerarlo solo' -ForegroundColor Yellow
            Write-Host '   aplaza el problema: el bot volvera a quedarse mudo, y el sintoma' -ForegroundColor Yellow
            Write-Host '   despista porque el dia anterior funcionaba.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '   Token permanente (gratis, sin verificacion de negocio):' -ForegroundColor Cyan
            Write-Host '     1. business.facebook.com/settings > Usuarios > Usuarios del sistema'
            Write-Host '     2. Agregar > rol Administrador'
            Write-Host '     3. Agregar activos > DOS cosas, no una:'
            Write-Host '          - Apps > tu app > Administrar app'
            Write-Host '          - Cuentas de WhatsApp > tu WABA > control total'
            Write-Host '        (con solo la app, el token se genera pero no puede leer'
            Write-Host '         numeros ni enviar mensajes)'
            Write-Host '     4. Generar token nuevo > permisos:'
            Write-Host '          whatsapp_business_messaging'
            Write-Host '          whatsapp_business_management'
            Write-Host '     5. Caducidad: Nunca'
            Write-Host ''
            Write-Host '   Detalle: docs/09-registrar-numero-whatsapp.md (paso 3)' -ForegroundColor DarkGray
            $problemas += 'token caducado (es el temporal de API Setup)'
        }
        else {
            Write-Host '   Causas mas frecuentes:' -ForegroundColor DarkGray
            Write-Host '     - Se copio incompleto (son varios cientos de caracteres).' -ForegroundColor DarkGray
            Write-Host '     - Es el App Secret o el App ID en vez del access token.' -ForegroundColor DarkGray
            Write-Host '     - El token es de otra app distinta a la que estas configurando.' -ForegroundColor DarkGray
            Write-Host "     - La version $Version de la Graph API ya no existe: prueba -Version v24.0" -ForegroundColor DarkGray
            $problemas += 'token invalido'
        }
        # No se aborta: la comprobacion de la suscripcion (seccion 4) usa un
        # token de APP y no depende de este. Mejor informar de todo lo que
        # falla de una vez que obligar a repetir el diagnostico.
        $tokenInservible = $true
    }
}

# --------------------------------------------- 2. que cuenta de WhatsApp?
if ($tokenInservible) {
    Titulo '2 y 3. Cuenta y numeros'
    Ojo 'Se omiten: necesitan un token valido. Corrige el token y repite.'
}
else {
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
    $campos = 'id,display_phone_number,verified_name,code_verification_status,quality_rating,platform_type,name_status,is_official_business_account,status'
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
            Dato 'operativo (status)' "$($p.status)"
            Dato 'calidad' "$($p.quality_rating)"
            Dato 'plataforma' "$($p.platform_type)"
            $idsEncontrados += $p.id

            # Quien manda es `status`, no `code_verification_status`.
            #
            # Un NUMERO DE PRUEBA de Meta figura SIEMPRE como NOT_VERIFIED: lo
            # provisiona Meta y no hay ningun SMS que confirmar. Aun asi envia y
            # recibe con normalidad hacia los destinatarios de la lista blanca.
            # La version anterior de esta comprobacion lo declaraba roto y
            # mandaba a "completar la verificacion por SMS", un paso que para un
            # numero de prueba no existe y no se puede completar.
            #
            # El campo que de verdad dice si el numero funciona es `status`:
            # CONNECTED = operativo. Un numero propio a medio registrar aparece
            # como PENDING o FLAGGED, y ahi si es un fallo real.
            $verificado = "$($p.code_verification_status)" -eq 'VERIFIED'
            $conectado = "$($p.status)" -eq 'CONNECTED'

            if ($conectado -and $verificado) {
                Bien 'Numero verificado y conectado.'
            }
            elseif ($conectado) {
                Bien 'Numero CONECTADO y operativo.'
                Ojo 'Figura como NOT_VERIFIED, que es lo normal en un numero de'
                Ojo 'prueba de Meta: no hay SMS que verificar. Envia y recibe solo'
                Ojo 'hacia los destinatarios registrados en la lista de prueba.'
            }
            else {
                Mal "El numero no esta operativo (status = $($p.status))."
                if (-not $verificado) {
                    Mal 'Completa la verificacion por SMS o llamada (docs/09, paso 5).'
                }
                $problemas += "numero $($p.display_phone_number) no operativo (status $($p.status))"
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

    # Con un numero de pruebas y uno real conviviendo en la misma cuenta, es
    # facil dejar el .env apuntando al que no es. Se dice a cual corresponde en
    # vez de limitarse a decir si existe.
    $coincide = $null
    if ($nums -and $nums.Ok -and $nums.Datos.data) {
        $coincide = @($nums.Datos.data | Where-Object { "$($_.id)" -eq $phoneIdEnv })[0]
    }

    if ($null -ne $coincide) {
        Bien "Apunta a: $($coincide.display_phone_number)  ($($coincide.verified_name))"
        # Meta entrega sus numeros de prueba con prefijo +1 555.
        if ("$($coincide.display_phone_number)" -replace '\D', '' -match '^1555') {
            Ojo 'Ese es el NUMERO DE PRUEBA de Meta, no una linea propia.'
            Ojo 'Solo puede escribir a los destinatarios registrados a mano (max. 5).'
        }
    }
    elseif ($idsEncontrados.Count) {
        Ojo 'Ese ID no corresponde a ninguno de los numeros de la WABA.'
        Ojo 'Probablemente quedo de otra configuracion. Numeros disponibles:'
        foreach ($p in $nums.Datos.data) {
            Write-Host "        $($p.id)  ->  $($p.display_phone_number)" -ForegroundColor DarkGray
        }
    }
}

}

# ------------------------------- 4. suscripcion de webhook de la app
# Esta comprobacion existe porque el WhatsApp Trigger de n8n registra el
# webhook EL MISMO al activarse, y se niega si la app ya tiene una suscripcion
# con otra callback_url:
#
#   "The WhatsApp App ID <id> already has a webhook subscription.
#    Delete it or use another App before executing the trigger."
#
# Es el fallo tipico cuando ya hubo intentos previos, otra herramienta o una
# configuracion manual en el panel de Meta.
Titulo '4. Suscripcion de webhook de la app'

$appId = Leer-Env 'WHATSAPP_APP_ID'
$appSecret = Leer-Env 'WHATSAPP_APP_SECRET'

if (-not $appId -or -not $appSecret) {
    Ojo 'Sin WHATSAPP_APP_ID y WHATSAPP_APP_SECRET no se puede comprobar.'
    Ojo 'Estan en Meta > Configuracion > Basica. Anadelos a .env.'
}
else {
    Dato 'App ID' $appId

    # Las suscripciones se consultan con un token de APP (app_id|app_secret),
    # no con el token de usuario del sistema.
    $tokenApp = "$appId|$appSecret"
    $urlSubs = "$GRAFO/$appId/subscriptions?access_token=" + [Uri]::EscapeDataString($tokenApp)

    $subs = $null
    $errSubs = ''
    try {
        $subs = Invoke-RestMethod -Uri $urlSubs -Method Get -TimeoutSec 30
    }
    catch {
        $errSubs = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $j = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($j.error) { $errSubs = "[#$($j.error.code)] $($j.error.message)" }
            }
            catch { }
        }
    }

    if ($errSubs) {
        Mal "No se pudo consultar: $errSubs"
        Write-Host '      Si dice "Invalid OAuth access token", el App Secret no' -ForegroundColor DarkGray
        Write-Host '      corresponde al App ID. Es el mismo error que hace que el bot' -ForegroundColor DarkGray
        Write-Host '      descarte TODOS los mensajes en silencio por firma invalida.' -ForegroundColor DarkGray
        $problemas += 'App ID/Secret no verificables'
    }
    else {
        $wa = @($subs.data | Where-Object { $_.object -eq 'whatsapp_business_account' })
        if ($wa.Count -eq 0) {
            Bien 'La app no tiene ninguna suscripcion de WhatsApp: n8n podra crearla.'
        }
        else {
            foreach ($s in $wa) {
                Dato 'callback_url' "$($s.callback_url)"
                Dato 'activa' "$($s.active)"
                $campos = @($s.fields | ForEach-Object { $_.name })
                Dato 'campos' $(if ($campos.Count) { $campos -join ', ' } else { '(ninguno)' })
            }
            # Una suscripcion previa solo es un problema si apunta a OTRO sitio.
            # Cuando ya se activo el workflow, la que hay es la que n8n registro,
            # y marcarla como fallo hacia que el diagnostico terminara en "HAY
            # QUE RESOLVER" con el bot funcionando perfectamente. Peor aun: la
            # salida sugeria borrarla, que es exactamente lo que NO hay que
            # hacer. Se compara contra WEBHOOK_URL de .env, que es la URL con la
            # que n8n se registro.
            $urlPropia = (Leer-Env 'WEBHOOK_URL').TrimEnd('/')
            $propias = @($wa | Where-Object { $urlPropia -and "$($_.callback_url)".StartsWith($urlPropia, [StringComparison]::OrdinalIgnoreCase) })

            if ($propias.Count -eq $wa.Count -and $wa.Count -gt 0) {
                Bien 'La suscripcion apunta a tu propio n8n: es la que registro el workflow.'
                $inactivas = @($wa | Where-Object { -not $_.active })
                if ($inactivas.Count -gt 0) {
                    Ojo 'Pero figura como INACTIVA en Meta: no va a entregar mensajes.'
                    $problemas += 'suscripcion de webhook inactiva en Meta'
                }
            }
            else {
                Ojo 'La app ya tiene una suscripcion de WhatsApp que NO es la tuya.'
                Write-Host ''
                Write-Host "      La tuya seria:  $urlPropia/..." -ForegroundColor DarkGray
                Write-Host '      Mientras esa siga puesta, la activacion del workflow' -ForegroundColor Yellow
                Write-Host '      FALLARA. Hay dos salidas:' -ForegroundColor Yellow
                Write-Host '        a) Borrarla: Meta > WhatsApp > Configuration > Webhook' -ForegroundColor DarkGray
                Write-Host '        b) Usar OTRA app de Facebook para este bot' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '      Meta solo admite UN WhatsApp Trigger por app.' -ForegroundColor DarkGray
                $problemas += 'la app tiene un webhook registrado que no es el tuyo'
            }
        }
    }
}

# ------------------------------- 4b. la WABA entrega a ESTA app?
#
# Son DOS suscripciones distintas y hacen falta las dos:
#
#   /{app-id}/subscriptions     la app dice "mi webhook esta en esta URL"
#   /{waba-id}/subscribed_apps  la WABA dice "mis eventos van a esta app"
#
# La seccion 4 comprueba la primera. Sin la SEGUNDA, Meta recibe los mensajes y
# los enruta a la app que si este suscrita: en una cuenta recien creada suele
# ser "WA DevX Webhook Events 1P App", la app interna que alimenta el panel de
# pruebas de Webhooks.
#
# Es el fallo mas desconcertante de todos porque no se parece a un fallo: el
# token es valido, el bot ENVIA sin problemas, el webhook figura registrado y
# activo, y el diagnostico entero da en orden. Simplemente no entra ni un
# mensaje, y no hay error en ninguna parte porque para Meta nada ha fallado.
if ($WabaId -and -not $tokenInservible) {
    Titulo '4b. La WABA entrega sus eventos a esta app?'

    $suscritas = Llamar "/$WabaId/subscribed_apps"
    if (-not $suscritas.Ok) {
        Ojo "No se pudo consultar: $($suscritas.Error)"
    }
    else {
        $lista = @($suscritas.Datos.data)
        if ($lista.Count -eq 0) {
            Mal 'La WABA no entrega sus eventos a NINGUNA app.'
            Mal 'Por eso no entra ningun mensaje aunque todo lo demas este bien.'
            $problemas += 'la WABA no esta suscrita a ninguna app'
        }
        else {
            foreach ($a in $lista) {
                $d = $a.whatsapp_business_api_data
                Dato 'app suscrita' "$($d.id)  $($d.name)"
            }
            $ids = @($lista | ForEach-Object { "$($_.whatsapp_business_api_data.id)" })
            $appIdEnv2 = Leer-Env 'WHATSAPP_APP_ID'
            if ($ids -contains $appIdEnv2) {
                Bien "La WABA entrega a tu app ($appIdEnv2)."
            }
            else {
                Mal "Tu app ($appIdEnv2) NO esta en la lista: no vas a recibir mensajes."
                Write-Host '      Se arregla solo al ejecutar:' -ForegroundColor DarkGray
                Write-Host '        powershell -File scripts/activar-whatsapp.ps1' -ForegroundColor DarkGray
                $problemas += 'la WABA no entrega los eventos a tu app'
            }
        }
    }
}

# --------------------------------------------------- 5. envio de prueba
if ($EnviarA) {
    Titulo '5. Envio de prueba'

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
