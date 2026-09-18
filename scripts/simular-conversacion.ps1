<#
.SYNOPSIS
  Conversa con el chatbot a traves del webhook del simulador, sin WhatsApp.

.DESCRIPTION
  Envia mensajes al workflow "Simulador local" y muestra las respuestas. Sirve
  para validar el flujo completo dentro de Docker sin cuenta de Meta ni
  credenciales de Google.

  REQUISITOS
  - El workflow "MERCAMIO - ChatBOT contable V07 (Simulador local)" ACTIVO.
  - Se usa la URL de PRODUCCION (/webhook/...), no la de prueba
    (/webhook-test/...): n8n solo guarda el estado de la conversacion en
    ejecuciones de produccion. Con la URL de prueba el bot saluda cada vez.

.PARAMETER Guion
  Nombre de un guion predefinido, o 'interactivo' para escribir a mano.
  Guiones: completo, cliente-retenciones, cliente-cartera, proveedor-factura,
           proveedor-certificado, acreedor-diferencia, acreedor-factura,
           acreedor-certificado, portal-proveedor, rechaza-datos, interactivo

.PARAMETER Telefono
  Numero que identifica la conversacion. Cambialo para empezar de cero.

.EXAMPLE
  powershell -File scripts/simular-conversacion.ps1
  powershell -File scripts/simular-conversacion.ps1 -Guion acreedor-diferencia
  powershell -File scripts/simular-conversacion.ps1 -Guion interactivo
#>
[CmdletBinding()]
param(
    [string]$Guion = 'completo',
    [string]$Telefono = '',
    # 127.0.0.1 y NO localhost: en Windows 11 `localhost` resuelve primero a ::1
    # y Docker Desktop no siempre responde por IPv6. Invoke-RestMethod no hace
    # el fallback a IPv4 que si hace curl, asi que con `localhost` da timeouts
    # intermitentes. Con la IP literal responde en ~1 ms.
    # (En el navegador `localhost` va bien: los navegadores si hacen fallback.)
    [string]$Url = 'http://127.0.0.1:5678/webhook/mercamio-sim'
)

$ErrorActionPreference = 'Stop'

# Telefono distinto en cada corrida: garantiza una conversacion desde cero.
if ([string]::IsNullOrWhiteSpace($Telefono)) {
    $Telefono = '5730' + (Get-Random -Minimum 10000000 -Maximum 99999999)
}

$guiones = @{
    'completo'              = @('hola', '1', 'Juan Perez', '1', '1', 'juan.perez@empresa.com')
    'cliente-retenciones'   = @('hola', '1', 'Juan Perez', '1', '1', 'juan.perez@empresa.com')
    'cliente-cartera'       = @('hola', '1', 'Ana Gomez', '1', '2', '900123456', 'ana.gomez@empresa.com')
    'proveedor-factura'     = @('hola', '1', 'Carlos Ruiz', '2', '2', '1', '900555444', 'FE-10023', 'RAD-88120')
    'proveedor-certificado' = @('hola', '1', 'Carlos Ruiz', '2', '3', '900555444', 'Retencion en la fuente 2025')
    'acreedor-diferencia'   = @('hola', '1', 'Marta Diaz', '3', '1', '901777888', 'FE-44501', '3250000')
    'acreedor-factura'      = @('hola', '1', 'Marta Diaz', '3', '2', '901777888', 'FE-44502', 'Jorge Restrepo')
    'acreedor-certificado'  = @('hola', '1', 'Marta Diaz', '3', '3', '901777888', 'Certificado de ingresos y retenciones')
    'portal-proveedor'      = @('hola', '1', 'Luis Mora', '2', '1')
    'rechaza-datos'         = @('hola', '2')
}

function Enviar-Mensaje {
    param([string]$Texto)

    $cuerpo = @{ from = $Telefono; text = $Texto } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $cuerpo -TimeoutSec 30
    }
    catch {
        Write-Host ''
        Write-Host 'No se pudo llamar al webhook.' -ForegroundColor Red
        Write-Host "  URL: $Url"
        Write-Host "  $($_.Exception.Message)"
        Write-Host ''
        Write-Host 'Comprobaciones:' -ForegroundColor Yellow
        Write-Host '  - docker compose ps            (n8n debe estar running/healthy)'
        Write-Host '  - El workflow "Simulador local" debe estar ACTIVO en la interfaz.'
        Write-Host '  - Un 404 casi siempre significa que el workflow esta inactivo.'
        exit 1
    }
    return $r
}

Write-Host ''
Write-Host "Conversacion: $Telefono" -ForegroundColor DarkGray
Write-Host "Webhook:      $Url" -ForegroundColor DarkGray
Write-Host ('-' * 72) -ForegroundColor DarkGray

if ($Guion -eq 'interactivo') {
    Write-Host 'Escribe mensajes. Linea vacia o "salir" para terminar.' -ForegroundColor DarkGray
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    while ($true) {
        $texto = Read-Host 'tu'
        if ([string]::IsNullOrWhiteSpace($texto) -or $texto -eq 'salir') { break }
        $r = Enviar-Mensaje -Texto $texto
        Write-Host "bot > $($r.respuesta)" -ForegroundColor Green
        Write-Host "      [accion=$($r.accion) estado=$($r.estado) ruta=$($r.ruta)]" -ForegroundColor DarkGray
    }
    exit 0
}

if (-not $guiones.ContainsKey($Guion)) {
    Write-Host "Guion desconocido: $Guion" -ForegroundColor Red
    Write-Host "Disponibles: $($guiones.Keys -join ', '), interactivo"
    exit 1
}

$ticketFinal = $null
foreach ($mensaje in $guiones[$Guion]) {
    Write-Host "tu  > $mensaje" -ForegroundColor White
    $r = Enviar-Mensaje -Texto $mensaje
    Write-Host "bot > $($r.respuesta)" -ForegroundColor Green
    Write-Host "      [accion=$($r.accion) estado=$($r.estado) ruta=$($r.ruta)]" -ForegroundColor DarkGray
    Write-Host ''
    if ($null -ne $r.ticket -and $r.ticket.PSObject.Properties.Name -contains 'ticket_id') {
        $ticketFinal = $r.ticket
    }
}

Write-Host ('-' * 72) -ForegroundColor DarkGray
if ($null -ne $ticketFinal) {
    Write-Host 'Ticket generado:' -ForegroundColor Cyan
    $ticketFinal | Format-List
}
else {
    Write-Host 'El guion termino sin generar ticket (ruta de cierre).' -ForegroundColor DarkGray
}
