# Despliegue de `security-app` en AWS ECS/Fargate

Despliega los 7 servicios de `docker-compose.yml` (`rabbitmq`, `postgres`,
`mongo`, `user-service`, `nmap-service`, `gateway`, `front`) en ECS/Fargate,
**sin bases de datos gestionadas**: Postgres, Mongo y RabbitMQ siguen siendo
contenedores, igual que en local. Pensado para demo/entrega de curso — sin
persistencia de datos entre reinicios.

**Dos formas de levantarlo, misma arquitectura base:**
- **[CONSOLE_GUIDE.md](./CONSOLE_GUIDE.md)** — paso a paso por la consola
  web de AWS (GUI).
- Los scripts `NN-*.sh` de esta carpeta — la misma secuencia automatizada
  con AWS CLI. **Esta es la que se está usando actualmente.**

Ambos caminos comparten los mismos `task-defs/*.json` (las 7 task
definitions) y crean exactamente los mismos recursos con los mismos
nombres, así que se puede mezclar (por ejemplo, crear la red por consola y
las imágenes con el script `05-build-push-core-images.sh`) sin problema.
Ambos incluyen el login real de Google (HTTPS autofirmado + credenciales
reales) — ver "Habilitar login real con Google" más abajo para la ruta de
scripts (`15`-`17`).

## Prerrequisitos

- AWS CLI v2 configurado (`aws configure`) con permisos de administrador o
  al menos: ECS, ECR, EC2 (security groups/ALB), IAM (leer/crear rol), Cloud
  Map/Service Discovery, CloudWatch Logs.
- Docker corriendo localmente (los builds de imagen se hacen en tu máquina).
- `jq` instalado (lo usa `16-update-gateway-oauth.sh` para editar campos
  puntuales de la task definition de `gateway` sin tocar el archivo del
  repo).
- `openssl` instalado (para el certificado autofirmado de
  `15-enable-https-gateway.sh` — viene preinstalado en Linux/macOS).
- **Cuenta de AWS Academy Learner Lab**: `EXEC_ROLE_NAME` en `00-env.sh` ya
  viene apuntando a `LabRole` (el rol preexistente de la cuenta) en vez de
  crear uno nuevo — Academy no permite `iam:CreateRole`. `03-iam-roles.sh`
  solo lo resuelve, no lo crea, y `99-cleanup.sh` nunca lo borra. Si tu
  cuenta de Academy usa otro nombre de rol, cambia `EXEC_ROLE_NAME` en
  `00-env.sh`.
- **Cuenta propia (no Academy) sin ese rol**: cambia `EXEC_ROLE_NAME` por el
  nombre que prefieras y crea el rol a mano (trust policy para
  `ecs-tasks.amazonaws.com` + policy `AmazonECSTaskExecutionRolePolicy`
  adjunta) antes de correr `03-iam-roles.sh`.
- Los certificados TLS de laboratorio del broker ya generados (ver
  `../../START.md` §0 — `../broker/rabbitmq/generate-lab-certs.sh` si hace
  falta): `05-build-push-core-images.sh` los necesita para construir
  `rabbitmq-custom` y para hornear el CA cert en `nmap-service`.

## Orden de ejecución

```bash
cd deploy/aws
./01-prereqs-check.sh
./02-ecr-repos.sh
./03-iam-roles.sh
./04-network.sh
./05-build-push-core-images.sh      # user-service, nmap-service, gateway, rabbitmq-custom
./06-alb.sh                         # crea el ALB primero para conocer su DNS
./07-build-push-front-image.sh      # front necesita el DNS del ALB (VITE_GATEWAY_BASE_URL)
./08-ecs-cluster-namespace-logs.sh
./09-register-task-defs.sh
./10-deploy-tier0-infra.sh          # postgres, mongo, rabbitmq
./11-deploy-tier1-services.sh       # user-service, nmap-service
./12-deploy-tier2-gateway.sh
./13-deploy-front.sh
./14-verify.sh
```

Cada script guarda los IDs/ARNs que crea en `.state/` (ignorado por git) para
que el siguiente los reutilice — es el reemplazo manual del state de
Terraform. Todos son idempotentes: se pueden re-correr sin duplicar
recursos.

En este punto el sistema ya funciona con el placeholder de Google (se ve el
redirect a Google, pero el login no completa) — igual que en local. Para
que el login funcione de punta a punta, sigue con la siguiente sección.

## Habilitar login real con Google

Google exige que el `redirect_uri` sea `https://` (salvo `localhost`), y el
ALB de los pasos anteriores solo tiene listeners HTTP. Estos 3 scripts
agregan un certificado autofirmado (sin dominio ni costo, mismo patrón que
`broker/rabbitmq/generate-lab-certs.sh`) y registran credenciales reales,
sin tocar `postgres`/`mongo`/`rabbitmq`/`user-service`/`nmap-service`:

```bash
./15-enable-https-gateway.sh
```
Genera el certificado (o reutiliza el ya importado), lo importa a ACM,
pasa el listener :8080 del gateway a HTTPS, crea un listener HTTPS:443 para
`front` y convierte :80 en un redirect a https://, y al final imprime el
`redirect_uri` exacto a usar. `front` también tiene que ir por HTTPS:
gateway emite la cookie de sesión con `Secure` + `SameSite=Strict`, y para
el navegador `http://ALB` y `https://ALB:8080` son sitios distintos — con
`front` en http:// la cookie no viaja en sus llamadas y todo da 401 tras el
login.

Se puede correr apenas existe el ALB (después de `06-alb.sh`): así
`07`/`09` ya construyen `front` y registran `gateway` con las URLs
`https://` y no hace falta reconstruir después. Con ese valor, en [console.cloud.google.com](https://console.cloud.google.com):
1. **OAuth consent screen**: User Type External, scopes `openid`,
   `.../auth/userinfo.email`, `.../auth/userinfo.profile`, y agrega como
   *test user* la(s) cuenta(s) Gmail que van a hacer login.
2. **Credentials → Create credentials → OAuth client ID** (Web
   application), pega el `redirect_uri` que imprimió el script, copia el
   **Client ID** y **Client secret**.

```bash
export GOOGLE_CLIENT_ID="..."
export GOOGLE_CLIENT_SECRET="..."
./16-update-gateway-oauth.sh   # nueva revisión de la task def de gateway con las credenciales reales
                               # (las guarda en .state/google_oauth.env: re-correr 09 ya no las pierde)
./17-rebuild-front-https.sh    # front reconstruido apuntando al gateway por https
```

Al iniciar sesión el navegador va a mostrar la advertencia de "conexión no
privada" dos veces (login y callback) — es el certificado de laboratorio,
no uno de una CA pública; clic en "Avanzado → Continuar" cada vez.

Si el ALB se recrea después (DNS distinto), hay que repetir estos 3 scripts
completos (el certificado y el redirect URI quedan atados al DNS anterior).

## Al terminar la demo

```bash
./99-cleanup.sh
```

Borra services, cluster, ALB, target groups, security groups, namespace,
log groups y repos ECR — evita que 7 tasks Fargate + 1 ALB sigan facturando
por hora entre sesiones de prueba. **No borra `LabRole`/`EXEC_ROLE_NAME`**:
es un rol preexistente que este despliegue nunca creó.

## Limitaciones aceptadas de esta ruta (scripts CLI)

- Sin persistencia: si una task de `postgres`/`mongo`/`rabbitmq` se
  reinicia, arranca vacía. (Aplica también a `CONSOLE_GUIDE.md`.)
- El certificado del ALB es autofirmado: el navegador muestra una
  advertencia de seguridad en `https://ALB/` y en `https://ALB:8080/` —
  hay que aceptarla en **ambas** (abre una vez `https://ALB:8080/health` y
  acepta), si no los `fetch()` de `front` al gateway fallan en silencio.
- El healthcheck de `rabbitmq` comprueba que 5672/5671 acepten conexiones
  (`bash </dev/tcp/...`) en vez de `rabbitmq-diagnostics check_running`:
  en la imagen `rabbitmq-custom` el servidor arranca vía `gosu`, que fija
  `HOME=/var/lib/rabbitmq`, mientras la CLI del healthcheck usa el
  `HOME=/var/lib/rabbitmq-runtime` del Dockerfile — cookies Erlang
  distintas, "Invalid challenge reply", y ECS reemplazaba la task cada
  pocos minutos. `gateway` no se reconecta solo al broker: si `rabbitmq` se
  reinicia, fuerza un redeploy de `gateway` y `nmap-service`.
- Windows: correr los scripts desde **Git Bash**. `00-env.sh` fija
  `MSYS_NO_PATHCONV=1` (si no, `/ecs/...` llega a `aws.exe` como
  `C:/Program Files/Git/ecs/...`) y expresa las rutas como `C:/...`.
- Si el ALB se recrea (DNS distinto), hay que repetir
  `06-alb.sh` → `07-build-push-front-image.sh` → (si se había hecho login
  real) `15` → `16` → `17` de nuevo, porque el certificado, el redirect URI
  registrado en Google y las URLs horneadas en `front` quedan atados al DNS
  anterior.
