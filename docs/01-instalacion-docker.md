# 01 — Instalar Docker en Windows

Guía para llegar desde una máquina sin Docker hasta `docker compose version`
respondiendo. Si ya tienes Docker Desktop funcionando, salta a
[02 — n8n en local](02-n8n-local-paso-a-paso.md).

---

## Requisitos de la máquina

| | Mínimo |
|---|---|
| Windows | 10 versión 22H2 o Windows 11 |
| RAM | 8 GB (la pila usa ~2 GB) |
| Disco libre | 15 GB — las imágenes de n8n y PostgreSQL ocupan ~1,3 GB, el resto es WSL2 y los datos |
| Virtualización | Habilitada en la BIOS/UEFI |

Comprobar la virtualización:

```powershell
Get-ComputerInfo -Property "HyperV*"
```

Si `HyperVRequirementVirtualizationFirmwareEnabled` sale `False`, hay que
habilitar **Intel VT-x** o **AMD-V** en la BIOS. Sin eso, WSL2 no arranca y
Docker Desktop no llega a levantar.

---

## Paso 1 — WSL2

Docker Desktop usa WSL2 como motor. Se instala antes.

En PowerShell **como administrador**:

```powershell
wsl --install
```

Reinicia cuando lo pida. Después:

```powershell
wsl --set-default-version 2
wsl --status
```

Debe decir `Versión predeterminada: 2`. Si ya tenías WSL:

```powershell
wsl --update
```

### Limitar el consumo de memoria de WSL2

Por defecto WSL2 puede reclamar hasta el 50 % de la RAM y no la devuelve al
sistema. En una máquina de trabajo eso se nota. Crea
`C:\Users\<tu-usuario>\.wslconfig`:

```ini
[wsl2]
memory=4GB
processors=2
swap=2GB
```

Aplícalo con `wsl --shutdown` (Docker Desktop se reiniciará solo).

No es obligatorio, pero evita la queja habitual de *"Docker me dejó el PC
lento"*.

---

## Paso 2 — Docker Desktop

1. Descarga el instalador desde <https://docs.docker.com/desktop/setup/install/windows-install/>
2. Ejecútalo dejando marcado **Use WSL 2 instead of Hyper-V**.
3. Reinicia.
4. Abre Docker Desktop y espera a que el icono de la ballena deje de moverse.

### Ajustes recomendados

En **Settings → Resources**: 4 GB de memoria y 2 CPU son suficientes.

En **Settings → General**: activa **Start Docker Desktop when you sign in to
your computer**. Sin esto, tras cada reinicio los contenedores están parados y
el bot no responde — un fallo que despista porque no hay ningún error, solo
silencio.

> Docker Desktop es gratuito para uso personal y para empresas pequeñas
> (menos de 250 empleados y menos de 10 M USD de ingresos anuales). Por encima
> de eso requiere licencia de pago. Verifica en qué categoría está MERCAMIO
> antes de desplegarlo en más equipos.

---

## Paso 3 — Verificar

```powershell
docker --version
docker compose version
docker run --rm hello-world
```

Las tres deben funcionar. Lo importante es `docker compose version` (con
espacio, plugin v2), no `docker-compose` (guion, v1 descatalogado).

```
Docker version 29.7.2, build a7dcaa6
Docker Compose version v5.5.0
```

---

## Problemas frecuentes

### `docker: error during connect ... The system cannot find the file specified`

Docker Desktop no está corriendo. Ábrelo y espera a que termine de arrancar.

### `WSL 2 installation is incomplete`

```powershell
wsl --update
wsl --shutdown
```

Y reinicia Docker Desktop.

### El puerto 5678 ya está en uso

```powershell
netstat -ano | Select-String ":5678"
Get-Process -Id <el-PID-de-la-ultima-columna>
```

Si es otra instancia de n8n, párala. Si es otra cosa, cambia el puerto en
`.env`:

```ini
N8N_PORT_HOST=5679
```

Y recuerda que `WEBHOOK_URL` debe apuntar al puerto nuevo.

### Rutas de Git Bash reescritas dentro de los contenedores

En **Git Bash** (no en PowerShell), una ruta absoluta del contenedor se
convierte a ruta de Windows:

```bash
docker compose exec n8n ls /workflows
# ls: C:/Program Files/Git/workflows: No such file or directory
```

Es MSYS convirtiendo `/workflows`. Dos soluciones:

```bash
MSYS_NO_PATHCONV=1 docker compose exec n8n ls /workflows   # recomendada
docker compose exec n8n ls //workflows                     # doble barra
```

En PowerShell no pasa. Los scripts de este repositorio son de PowerShell
precisamente por esto.

### `Invoke-RestMethod` da timeout contra `localhost` pero curl funciona

En Windows 11, `localhost` resuelve **primero a `::1`** (IPv6) y Docker Desktop
no siempre responde por ahi. `curl` reintenta por IPv4 y funciona, aunque tarda
~1,2 s en vez de ~1 ms. `Invoke-RestMethod` **no hace ese fallback**: agota el
`-TimeoutSec` y lanza `WebException`.

```powershell
[System.Net.Dns]::GetHostAddresses('localhost')
#   InterNetworkV6 : ::1        <- se intenta primero
#   InterNetwork   : 127.0.0.1

Invoke-RestMethod http://localhost:5678/healthz -TimeoutSec 6   # timeout
Invoke-RestMethod http://127.0.0.1:5678/healthz -TimeoutSec 6   # ok en 1 ms
```

**Regla:** en scripts de PowerShell usa siempre `127.0.0.1`. En el navegador
`localhost` va bien, porque los navegadores si hacen el fallback rapido.

Los scripts de este repositorio ya usan `127.0.0.1`. Este fallo produjo un
falso negativo real en la espera de arranque de `importar-workflows.ps1`:
reportaba que n8n no habia vuelto cuando Docker lo daba por `healthy`.

### `NativeCommandError` al ejecutar docker desde un script

En Windows PowerShell 5.1, redirigir el stderr de un ejecutable nativo
(`docker compose restart n8n *>$null` o `2>&1`) envuelve cada linea en un
`ErrorRecord` de tipo `NativeCommandError` y pone `$?` en `$false`, **aunque el
comando haya devuelto 0**. Con `$ErrorActionPreference = 'Stop'` eso aborta el
script. docker escribe su progreso en stderr, asi que le pasa siempre.

Solucion: no redirigir stderr. Bajar la preferencia de error solo durante la
llamada y consultar `$LASTEXITCODE`, que si es fiable. Ver la funcion
`Invocar-Nativo` en [`scripts/importar-workflows.ps1`](../scripts/importar-workflows.ps1).

### Lentitud al leer archivos montados

El volumen `./workflows:/workflows:ro` cruza la frontera entre Windows y WSL2 y
es lento. Aquí no importa (dos archivos que se leen una vez al importar), pero
no metas ahí nada que se lea con frecuencia.

---

## Siguiente

[02 — n8n en local paso a paso](02-n8n-local-paso-a-paso.md)
