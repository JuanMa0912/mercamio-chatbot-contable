# 10 — Qué cuesta de verdad

Separar tres cosas que suelen mezclarse: lo que es gratis, lo que cuesta dinero,
y lo que cuesta sin ser dinero.

---

## La buena noticia: este bot en concreto no paga mensajes

WhatsApp Cloud API **no cobra por las conversaciones de servicio**: las que
inicia el usuario y que tú respondes dentro de la ventana de 24 horas. Meta las
dejó gratis, sin límite mensual, en noviembre de 2024.

Este bot es **100 % reactivo**: el proveedor escribe, el bot responde. Todas sus
conversaciones son de servicio. No hay nada que pagar por los mensajes.

Lo que sí se cobra son las **plantillas** (marketing, utilidad, autenticación),
que van por mensaje desde julio de 2025. El bot no envía ninguna.

> **Empezaría a costar** el día que se añadan notificaciones de seguimiento
> ("tu ticket MCM-xxx se resolvió"). Esos mensajes salen fuera de la ventana de
> 24 h, exigen plantilla aprobada y se cobran por unidad. Está en la lista de
> deuda técnica de [05](05-auditoria-workflow.md#deuda-técnica-pendiente) y no
> se ha implementado.

Los precios de Meta cambian con frecuencia y cualquier cifra escrita en un
documento envejece mal. Los tuyos, reales y actuales, están en tu propia cuenta:
**WhatsApp Manager → Insights**. No te fíes de un número copiado de un blog, ni
del que pueda quedar aquí.

---

## El costo que probablemente no has visto: Docker Desktop

Esta máquina usa **Docker Desktop**, no Docker Engine:

```
Servidor: 29.7.2 | OS: Docker Desktop | contexto: desktop-linux
```

Docker Desktop es gratis para uso personal, educación, open source no comercial
y **empresas de menos de 250 empleados Y menos de 10 M USD de ingresos anuales**.
Hay que cumplir **las dos** condiciones.

**Comprueba en cuál cae MERCAMIO.** Si supera cualquiera de las dos, Docker
Desktop requiere licencia de pago por cada persona que lo use — y no es un
detalle legal teórico: Docker ha hecho auditorías a empresas.

### La alternativa gratis: Docker Engine dentro de WSL2

Docker **Engine** es Apache 2.0 y gratis sin condiciones. Docker **Desktop** es
la interfaz gráfica y el instalador de Windows lo que se licencia.

```powershell
# 1. Una distro de WSL2 (si no la tienes)
wsl --install -d Ubuntu

# 2. Dentro de Ubuntu, instalar Docker Engine
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER

# 3. Que arranque solo al abrir WSL
echo 'sudo service docker start >/dev/null 2>&1' >> ~/.bashrc
```

Después, el proyecto se clona **dentro** del sistema de archivos de WSL
(`~/mercamio-chatbot-contable`), no en `/mnt/c/...`: cruzar la frontera
Windows↔WSL en cada lectura es lento.

`localhost:5678` sigue funcionando desde Windows — WSL2 reenvía los puertos.

**Lo que se pierde:** la interfaz gráfica de Docker Desktop, el arranque
automático con Windows, y la integración con el explorador de archivos. Todo se
opera por terminal. Para este proyecto, que ya se maneja con scripts, la
pérdida es pequeña.

**Lo que cuesta:** una tarde de migración y reconstruir los volúmenes. La
`N8N_ENCRYPTION_KEY` de `.env` es lo que permite que las credenciales sigan
funcionando; expórtalas antes por si acaso (ver *Copia de seguridad* en el
[README](../README.md)).

No lo he hecho en esta máquina. Si MERCAMIO está por debajo de los umbrales, no
hace falta tocar nada.

---

## Inventario completo

| Pieza | Coste | Nota |
|---|---|---|
| **WhatsApp Cloud API** | 0 para este bot | Conversaciones de servicio gratis. Plantillas se cobran; no se usan. |
| **Número de prueba de Meta** | 0 | No consume línea. Máximo 5 destinatarios. |
| **Número propio** | el de la línea | Y deja de poder usarse en la app ([09](09-registrar-numero-whatsapp.md)). |
| **Business Verification** | 0 | Solo papeleo y tiempo. |
| **n8n Community** | 0 | Sustainable Use License: permite uso interno de la propia empresa. |
| **PostgreSQL** | 0 | PostgreSQL License. |
| **Cloudflare Tunnel** | 0 | Tanto el rápido como el nombrado. El nombrado necesita un dominio, y `mercamio.com.co` ya existe. |
| **Google Sheets** | 0 | Con cuenta normal. Si ya hay Workspace, ya está pagado. |
| **Docker Desktop** | **depende** | Gratis solo si <250 empleados **y** <10 M USD. Ver arriba. |
| **El PC encendido** | electricidad | Y algo peor, abajo. |

---

## El costo que no es dinero, y es el que más pesa

El bot corre en un PC de escritorio en la oficina. Eso significa:

| Lo que pasa | Lo que ve el proveedor |
|---|---|
| El PC se suspende | Silencio |
| Windows reinicia por actualización | Silencio |
| Alguien cierra Docker Desktop | Silencio |
| Se va la luz | Silencio |
| Alguien apaga el PC el viernes | Silencio todo el fin de semana |

**Y nadie se entera.** No hay error, no hay alerta. Meta reintenta la entrega un
rato y luego descarta el mensaje. El proveedor escribe, no recibe nada, y
concluye que MERCAMIO no contesta. Es peor que no tener bot: el proveedor ya
esperaba una respuesta automática.

Además, mientras el PC esté apagado, las conversaciones a medias caducan por el
TTL de 60 minutos. Quien estaba a mitad de dar sus datos tiene que empezar de
cero.

### Mitigaciones, de menos a más

1. **Gratis, imprescindible:** en Docker Desktop, *Settings → General → Start
   Docker Desktop when you sign in*. Y en Windows, desactivar la suspensión:

   ```powershell
   powercfg /change standby-timeout-ac 0
   powercfg /change hibernate-timeout-ac 0
   ```

   El `restart: unless-stopped` del compose ya hace que los contenedores
   vuelvan solos cuando Docker arranca.

2. **Gratis, muy recomendable:** una alerta que avise cuando el bot lleva un
   rato sin responder. Un `/loop` que haga `GET /healthz` y te escriba si falla,
   o un monitor externo gratuito (UptimeRobot tiene plan gratis) apuntando a la
   URL del túnel.

3. **De pago, si el bot pasa a producción:** un VPS de 5–10 USD/mes. Por ese
   precio desaparecen el problema de disponibilidad, el de Docker Desktop
   (Engine en Linux es gratis) y el del túnel (IP pública directa). Para un
   canal por el que van a entrar proveedores reales, es barato.

---

## Recomendación

**Para el piloto:** todo gratis, tal como está, en el PC. Es lo correcto — no
tiene sentido pagar por un VPS antes de saber si las 9 rutas sirven.

**Antes de decirle a un proveedor real que escriba al número:**

1. Resolver la licencia de Docker Desktop, o migrar a Engine en WSL2.
2. Poner la alerta de caída. Sin eso te vas a enterar por una queja.
3. Decidir si el PC de oficina es un sitio aceptable para un canal de atención.
   Mi lectura: no lo es, y el VPS de 5 USD resuelve tres problemas a la vez.

Lo verdaderamente gratis aquí es WhatsApp. Lo que cuesta es la disponibilidad —
y ese es un costo que se paga en credibilidad frente a los proveedores, no en
una factura.
