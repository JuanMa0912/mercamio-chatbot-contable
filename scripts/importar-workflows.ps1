<#
.SYNOPSIS
  Reconstruye los JSON de los workflows e importa ambos a la instancia de n8n.

.DESCRIPTION
  1. Ejecuta las pruebas del motor (si fallan, no se importa nada).
  2. Regenera workflows/*.json desde src/nodes/*.js.
  3. Importa en n8n con `n8n import:workflow`.

  Los workflows llevan id fijo (mercamioWa000001 / mercamioSim00001), asi que
  la importacion ACTUALIZA los existentes en vez de duplicarlos.

  La importacion NO activa los workflows ni toca las credenciales: eso se hace
  una sola vez desde la interfaz.

.PARAMETER SaltarPruebas
  Importa sin ejecutar las pruebas antes. Usalo solo para iterar rapido.

.EXAMPLE
  powershell -File scripts/importar-workflows.ps1
#>
[CmdletBinding()]
param(
    [switch]$SaltarPruebas
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

function Escribir-Paso { param([string]$Texto) Write-Host "==> $Texto" -ForegroundColor Cyan }
function Escribir-Error2 { param([string]$Texto) Write-Host "ERROR: $Texto" -ForegroundColor Red }

# Ejecuta un comando nativo descartando su salida y devuelve el codigo de salida.
#
# En Windows PowerShell 5.1, redirigir el stderr de un ejecutable nativo
# (`docker ... *>$null` o `2>&1`) envuelve cada linea en un ErrorRecord de tipo
# NativeCommandError y pone $? en $false, incluso cuando el comando devolvio 0.
# Con $ErrorActionPreference = 'Stop' eso aborta el script. docker escribe su
# progreso en stderr, asi que cualquier `docker compose` con redireccion falla.
#
# La solucion es NO redirigir el stderr: se baja la preferencia de error solo
# durante la llamada y se consulta $LASTEXITCODE, que si es fiable.
function Invocar-Nativo {
    param([Parameter(Mandatory = $true)][scriptblock]$Comando)

    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Comando | Out-Null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previo
    }
}

# --- 1. Pruebas del motor ----------------------------------------------------
if (-not $SaltarPruebas) {
    Escribir-Paso 'Ejecutando pruebas del motor conversacional'
    node --test tests/motor.test.mjs
    if ($LASTEXITCODE -ne 0) {
        Escribir-Error2 'Las pruebas fallaron. No se importa nada.'
        exit 1
    }
}

# --- 2. Reconstruir los JSON -------------------------------------------------
Escribir-Paso 'Generando los JSON de los workflows'
node scripts/build-workflow.mjs
if ($LASTEXITCODE -ne 0) { Escribir-Error2 'Fallo la generacion.'; exit 1 }

# --- 3. Comprobar que n8n responde -------------------------------------------
Escribir-Paso 'Comprobando que el contenedor de n8n esta arriba'
# El -join es obligatorio: docker devuelve varias lineas y en PowerShell el
# operador -notmatch sobre un ARRAY filtra en vez de comparar, asi que
# siempre devolveria algo distinto de $false.
$estado = (docker compose ps --format '{{.Service}}:{{.State}}' 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0) { Escribir-Error2 'docker compose no responde. Esta Docker Desktop arrancado?'; exit 1 }
if ($estado -notmatch 'n8n:running') {
    Escribir-Error2 'El contenedor de n8n no esta corriendo. Ejecuta: docker compose up -d'
    exit 1
}

# --- 4. Recordar que workflows estaban activos -------------------------------
# `n8n import:workflow` sobrescribe la fila completa, incluida la columna
# `active`, y los JSON generados llevan active: false. Sin este paso, cada
# importacion DESACTIVA el bot en silencio: el webhook empieza a devolver 404 y
# el unico sintoma es que WhatsApp deja de responder.
Escribir-Paso 'Anotando que workflows estan activos'
$consulta = "select id from workflow_entity where active = true and id like 'mercamio%';"
$activosAntes = @(
    (docker compose exec -T postgres psql -U n8n -d n8n -t -A -c $consulta) |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' }
)
if ($activosAntes.Count -gt 0) {
    Write-Host "    activos: $($activosAntes -join ', ')"
}
else {
    Write-Host '    ninguno activo todavia'
}

# --- 5. Importar -------------------------------------------------------------
# La ruta /workflows es DENTRO del contenedor (volumen ./workflows:/workflows:ro).
# En Git Bash habria que poner MSYS_NO_PATHCONV=1; PowerShell no reescribe rutas.
Escribir-Paso 'Importando los workflows en n8n'
$salida = docker compose exec -T n8n n8n import:workflow --separate --input=/workflows 2>&1
$salidaTexto = $salida -join "`n"
$salida | Where-Object {
    # "Could not remove webhooks ... Could not find workflow" es ruido normal:
    # n8n intenta desactivar un workflow que aun no existe en la base.
    $_ -notmatch 'Could not (remove webhooks|find workflow)' -and
    $_ -notmatch '^\s+at ' -and
    $_ -notmatch 'Error tracking disabled'
} | ForEach-Object { Write-Host "    $_" }

if ($salidaTexto -notmatch 'Successfully imported') {
    Escribir-Error2 'La importacion no confirmo exito. Revisa la salida de arriba.'
    exit 1
}

# --- 6. Restaurar la activacion ----------------------------------------------
if ($activosAntes.Count -gt 0) {
    Escribir-Paso 'Reactivando los workflows que estaban activos'
    foreach ($id in $activosAntes) {
        $codigo = Invocar-Nativo { docker compose exec -T n8n n8n update:workflow --id=$id --active=true }
        if ($codigo -ne 0) {
            Escribir-Error2 "No se pudo reactivar $id (codigo $codigo). Activalo a mano en la interfaz."
        }
        else {
            Write-Host "    reactivado: $id"
        }
    }
    # El reinicio es obligatorio: la propia CLI avisa de que la activacion no
    # surte efecto mientras n8n esta corriendo, porque el proceso en marcha no
    # vuelve a registrar los webhooks por su cuenta.
    Escribir-Paso 'Reiniciando n8n para reregistrar los webhooks'
    $codigoRestart = Invocar-Nativo { docker compose restart n8n }
    if ($codigoRestart -ne 0) {
        Escribir-Error2 "docker compose restart devolvio $codigoRestart. Revisa: docker compose logs n8n"
        exit 1
    }

    # OJO con la URL: se usa 127.0.0.1 y NO localhost.
    #
    # En Windows 11, `localhost` resuelve primero a ::1 (IPv6) y Docker Desktop
    # no siempre responde por ahi. curl hace fallback a IPv4 y tarda ~1,2 s,
    # pero Invoke-RestMethod NO hace ese fallback: agota el -TimeoutSec y lanza
    # WebException. Con 127.0.0.1 la misma peticion responde en ~1 ms.
    #
    # Este bucle daba un falso negativo por eso: reportaba que n8n no habia
    # vuelto cuando en realidad estaba healthy.
    $listo = $false
    foreach ($intento in 1..40) {
        Start-Sleep -Seconds 3
        try {
            if ((Invoke-RestMethod -Uri 'http://127.0.0.1:5678/healthz' -TimeoutSec 5).status -eq 'ok') {
                $listo = $true
                break
            }
        }
        catch { }
    }
    if (-not $listo) {
        # Segunda opinion sin tocar la pila de red de Windows: si Docker dice
        # que el contenedor esta healthy, el problema es de la comprobacion.
        $salud = (docker inspect --format '{{.State.Health.Status}}' mercamio-n8n 2>$null) -join ''
        if ($salud.Trim() -eq 'healthy') { $listo = $true }
    }
    if ($listo) {
        Write-Host ''
        Write-Host 'Listo. Los workflows siguen activos y los webhooks estan registrados.' -ForegroundColor Green
        Write-Host '  Prueba con: powershell -File scripts/simular-conversacion.ps1'
    }
    else {
        Escribir-Error2 'n8n no volvio a responder en /healthz. Revisa: docker compose logs n8n'
        exit 1
    }
}
else {
    Write-Host ''
    Write-Host 'Listo. Siguientes pasos en la interfaz (http://localhost:5678):' -ForegroundColor Green
    Write-Host '  1. Abre "MERCAMIO - ChatBOT contable V07 (Simulador local)".'
    Write-Host '  2. Activalo con el interruptor de arriba a la derecha.'
    Write-Host '  3. Prueba con: powershell -File scripts/simular-conversacion.ps1'
    Write-Host ''
    Write-Host 'IMPORTANTE: el workflow debe quedar ACTIVO. En modo prueba n8n' -ForegroundColor Yellow
    Write-Host 'descarta el estado de la conversacion y el bot saluda en cada mensaje.' -ForegroundColor Yellow
}
