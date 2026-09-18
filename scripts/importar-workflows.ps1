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
        docker compose exec -T n8n n8n update:workflow --id=$id --active=true *>$null
        Write-Host "    reactivado: $id"
    }
    # El reinicio es obligatorio: la propia CLI avisa de que la activacion no
    # surte efecto mientras n8n esta corriendo, porque el proceso en marcha no
    # vuelve a registrar los webhooks por su cuenta.
    Escribir-Paso 'Reiniciando n8n para reregistrar los webhooks'
    docker compose restart n8n *>$null

    $listo = $false
    foreach ($intento in 1..40) {
        Start-Sleep -Seconds 3
        try {
            if ((Invoke-RestMethod -Uri 'http://localhost:5678/healthz' -TimeoutSec 5).status -eq 'ok') {
                $listo = $true
                break
            }
        }
        catch { }
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
