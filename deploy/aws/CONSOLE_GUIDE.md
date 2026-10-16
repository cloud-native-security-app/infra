# Despliegue de `security-app` en AWS ECS/Fargate — vía consola web (GUI)

Misma arquitectura que `README.md`/los scripts de `deploy/aws/*.sh` (7
servicios ECS separados, Service Connect para DNS interno, un ALB con 2
listeners, sin bases de datos gestionadas), pero armada a mano en la consola
de AWS en vez de con AWS CLI. Los archivos `task-defs/*.json` de esta misma
carpeta se reutilizan tal cual: se pegan en el editor JSON de la consola de
ECS en vez de registrarse con `aws ecs register-task-definition`.

Esta guía además incluye login real con Google (no solo el placeholder):
el gateway hace Authorization Code + PKCE contra el issuer real de Google, y
Google exige que el redirect URI sea `https://` (excepto `localhost`). Para
eso se agrega un certificado **autofirmado** (mismo patrón que ya usa este
repo para el TLS de RabbitMQ) importado a ACM y atado a un listener HTTPS
del ALB — sin comprar dominio. El costo: el navegador muestra la advertencia
de "conexión no privada" dos veces durante el login (se hace clic en
"Avanzado → Continuar"), porque la CA es de laboratorio, no pública.

**Partes que requieren terminal**: construir/subir las 5 imágenes Docker
(`docker build`/`docker push` no tiene equivalente de clic) y generar el
certificado autofirmado con `openssl`. Todo lo demás (repos, roles, red,
ALB, ACM, cluster, task definitions, servicios, Google Cloud Console) se
hace 100% en la consola/navegador.

## Orden de trabajo

1. Antes de empezar: prerrequisitos, validación local y huecos conocidos (checklist de `START.md`)
2. Repos ECR (consola) + build/push de imágenes core (terminal, inevitable)
3. Rol IAM de ejecución (consola)
4. Red: security groups (consola)
5. Application Load Balancer + target groups — solo listener de `front` (consola)
6. Certificado autofirmado + listener HTTPS del gateway (terminal + ACM + ALB)
7. Configurar OAuth real con Google (Google Cloud Console)
8. Build/push de `front` (terminal, ya con HTTPS)
9. Cluster ECS + namespace Service Connect + log groups (consola)
10. Las 7 task definitions (consola, editor JSON)
11. Los 7 servicios ECS, por tiers (consola)
12. Verificación (terminal + navegador)
13. Cleanup (consola)

---

## 1. Antes de empezar (checklist de `START.md`)

Todo esto está copiado/adaptado de `../../START.md` para no tener que saltar
entre documentos — es el único que hace falta seguir para el deploy.

### 1.1 Prerrequisitos técnicos

- Acceso a la consola de AWS con permisos de administrador (o al menos:
  ECS, ECR, EC2/VPC, IAM, Cloud Map, CloudWatch Logs, ELB, ACM).
- Docker instalado localmente (para `docker build`/`docker push`).
- `openssl` instalado localmente (para el certificado autofirmado del
  paso 6 — viene preinstalado en Linux/macOS; en Windows usar Git Bash o WSL).
- AWS CLI instalado localmente **solo para autenticar Docker contra ECR**
  (`aws ecr get-login-password`) — la consola no tiene otra forma de generar
  esa credencial temporal para tu terminal. Si prefieres evitar instalar AWS
  CLI, puedes generar la contraseña de login vía **ECR → tu repo → View push
  commands**, que te da el comando exacto a copiar/pegar (igual usa `aws`
  por dentro).
- Una cuenta de Google (o proyecto en Google Cloud Console) para el paso 7
  — cualquier cuenta Gmail sirve para crear el proyecto.
- **Certificados TLS de laboratorio del broker ya generados** (`START.md`
  §0): si `broker/rabbitmq/tls/` no existe o está vacío, correr
  ```bash
  ./broker/rabbitmq/generate-lab-certs.sh
  ```
  Se hornean en la imagen `rabbitmq-custom` (paso 2) y en `nmap-service`
  (paso 2.2) — sin esto, ninguna de las dos imágenes se puede construir.

### 1.2 Validar en local antes de tocar AWS

Recomendado (no obligatorio, pero ahorra tiempo de debugging en la nube):
correr `docker compose up --build` una vez en local y confirmar que pasan
las verificaciones de `START.md` §2 antes de empezar el deploy — así
cualquier problema de build de imagen o de wiring entre servicios se detecta
en local, donde es mucho más rápido de iterar que en ECS:

```bash
docker compose up --build -d
curl -i http://localhost:15672                 # RabbitMQ management UI
curl -i http://localhost:8081/health           # user-service, 200 si Postgres responde
curl -i http://localhost:8080/health           # gateway, 200
curl -s http://localhost:8080/api/openapi.json | head -c 300
docker compose logs -f nmap-service            # sin errores de conexión AMQPS
```
Abre `http://localhost:8082` — debe verse la pantalla de login. Si todo esto
funciona en local, el mismo build (con las imágenes ya preparadas para
Fargate, ver paso 2) va a comportarse igual en AWS.

`docker compose down` cuando termines de validar, antes de pasar al paso 2.

### 1.3 Huecos conocidos que se heredan al deploy (no bloquean, pero hay que saberlo)

Documentados en `START.md` §"Huecos conocidos":

- **`POST /api/scans` responde `501`.** El handler de `gateway` ya llama a
  `user-service` para resolver `network_user`/`ssh_credentials_ref`/
  `has_sudo`, pero `user-service` todavía no implementa esa API. Es decir:
  **el flujo completo login → escaneo → resultado no se puede demostrar**,
  ni en local ni en AWS. Lo que sí se puede verificar end-to-end es todo lo
  demás (health checks, OpenAPI, perfil de usuario, historial vacío,
  `nmap-service` conectado y escuchando el Broker, y el login real con
  Google de los pasos 6-7).
- **`nmap-service` sí consume del Broker** (hueco ya cerrado) — se conecta
  por AMQPS y queda escuchando `ms-nmap.scan-requests`/
  `ms-nmap.scan-cancellations`. Para que esto funcione en AWS, el CA de
  laboratorio debe estar horneado en la imagen (paso 2.2) — si los logs de
  `nmap-service` muestran "no se pudo conectar al Broker (AMQPS)", revisa
  ese paso y el security group (puerto 5671 en `internal-sg`).
- **Login con Google**: a diferencia de local (donde `GOOGLE_CLIENT_ID`/
  `SECRET` quedan como placeholders y el login nunca completa), esta guía
  **sí lo deja funcional de punta a punta** en los pasos 6 y 7 (HTTPS
  autofirmado + credenciales OAuth reales) — con la salvedad de la
  advertencia de certificado del navegador ya mencionada arriba.

## 2. Repos ECR + build/push de imágenes core

### 2.1 Crear los 5 repos (consola)

**ECR → Repositories → Create repository**, uno por uno, con:
- Visibility: **Private**
- Repository name: `security-app/user-service`, `security-app/nmap-service`,
  `security-app/gateway`, `security-app/front`, `security-app/rabbitmq-custom`
- Scan on push: **Enabled**
- Tag mutability: **Mutable**

No crees repo para `postgres` ni `mongo`: se usan directamente los espejos
públicos `public.ecr.aws/docker/library/postgres:16-alpine` y
`.../mongo:7` en las task definitions (paso 10) — no requieren repo propio
ni login.

### 2.2 Build + push de las 4 imágenes que no dependen del ALB (terminal)

En cada repo creado, botón **View push commands** te da el login + build +
tag + push exactos con tu Account ID y región ya rellenados. En orden:

```bash
# user-service
docker build -t security-app/user-service ./user-service
docker tag security-app/user-service:latest 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/user-service:latest
3

# nmap-service (--build-context le da acceso al CA cert de broker/rabbitmq/tls/
# sin copiarlo — ver nmap-service/Dockerfile)
docker build --build-context tls=./broker/rabbitmq/tls -t security-app/nmap-service ./nmap-service
docker tag security-app/nmap-service:latest 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/nmap-service:latest
docker push 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/nmap-service:latest

# gateway
docker build -t security-app/gateway ./gateway
docker tag security-app/gateway:latest 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/gateway:latest
docker push 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/gateway:latest

# rabbitmq-custom
docker build -t security-app/rabbitmq-custom ./broker/rabbitmq
docker tag security-app/rabbitmq-custom:latest 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/rabbitmq-custom:latest
docker push 831984817561.dkr.ecr.us-east-1.amazonaws.com/security-app/rabbitmq-custom:latest
```

`front` queda pendiente hasta el paso 8 — necesita el DNS del ALB **con
HTTPS** como build-arg. Anota en algún lado los 4 URIs de imagen completos
(`<repo>:latest`), los vas a pegar en las task definitions del paso 10.

## 3. Rol IAM de ejecución

**Si usas AWS Academy Learner Lab**: no se crea ningún rol — Academy no
permite `iam:CreateRole`. Ve directo a **IAM → Roles → `LabRole`** (el rol
preexistente de la cuenta), ábrelo y copia su **ARN**. Sigue directo al
paso 4; el resto de esta sección no aplica.

**Si tienes una cuenta propia con permisos de IAM**: **IAM → Roles →
Create role**:
- Trusted entity type: **AWS service**
- Use case: **Elastic Container Service** → **Elastic Container Service Task**
- Permissions: adjunta la policy administrada
  **AmazonECSTaskExecutionRolePolicy**
- Nombre: `security-app-ecs-execution-role`
- Crea el rol y copia su **ARN** (lo vas a pegar en cada task definition).

En ambos casos no hace falta un Task Role separado: ningún contenedor llama
a APIs de AWS desde dentro (todos los secretos son placeholders de
laboratorio inyectados como env var plana, igual que en
`docker-compose.yml`).

## 4. Red: 2 security groups

Usa la **VPC default** de tu cuenta (no hace falta crear una nueva) —
**VPC → Your VPCs**, confirma cuál tiene la columna "Default VPC" = Yes, y
anota sus subnets públicas (**VPC → Subnets**, filtra por esa VPC; todas las
de la default tienen IP pública automática).

**EC2 → Security Groups → Create security group**:

**a) `security-app-alb-sg`** (solo el ALB):
| Tipo | Protocolo | Puerto | Origen |
|---|---|---|---|
| Custom TCP | TCP | 80 | Anywhere-IPv4 (0.0.0.0/0) |
| Custom TCP | TCP | 8080 | Anywhere-IPv4 (0.0.0.0/0) |

(El puerto 8080 sirve tanto para el listener HTTP inicial como para el
HTTPS que se agrega en el paso 6 — un security group solo filtra por
puerto/protocolo TCP, no distingue HTTP de HTTPS.)

**b) `security-app-internal-sg`** (todas las tasks ECS):
| Tipo | Protocolo | Puerto | Origen |
|---|---|---|---|
| Custom TCP | TCP | 5432 | **este mismo SG** (selecciónalo por nombre/ID) |
| Custom TCP | TCP | 27017 | este mismo SG |
| Custom TCP | TCP | 5672 | este mismo SG |
| Custom TCP | TCP | 5671 | este mismo SG |
| Custom TCP | TCP | 15672 | este mismo SG |
| Custom TCP | TCP | 8080 | este mismo SG |
| Custom TCP | TCP | 8080 | `security-app-alb-sg` |

La última regla es la que deja al ALB llegar a `front`/`gateway` — sin ella
el ALB marca los targets como *unhealthy* aunque las tasks estén bien. Al
seleccionar "este mismo SG" como origen, AWS lo guarda como una regla
self-referencing (cualquier task del grupo puede hablarle a cualquier otra).

## 5. Application Load Balancer + target groups (solo `front` por ahora)

### 5.1 Target groups

**EC2 → Target Groups → Create target group**, dos veces:

**`security-app-front-tg`**:
- Target type: **IP addresses**
- Protocol: HTTP, Port: **8080**
- VPC: la default
- Health check path: `/`
- Healthy threshold: 2, Unhealthy threshold: 3, Interval: 15s

**`security-app-gateway-tg`**: igual, pero Health check path: `/health`.
(Se usa recién en el paso 6, pero créalo ahora junto con el otro.)

No agregues targets todavía (los servicios ECS del paso 11 se registran
solos).

### 5.2 El ALB — solo el listener de `front`

**EC2 → Load Balancers → Create load balancer → Application Load Balancer**:
- Scheme: **Internet-facing**
- VPC: la default, selecciona las subnets públicas
- Security group: `security-app-alb-sg` (quita el "default" que propone)
- Listener: HTTP **80** → forward a `security-app-front-tg`
- Nombre: `security-app-alb`

**No agregues el listener 8080 todavía** — se crea en el paso 6, ya como
HTTPS, una vez que exista el certificado autofirmado (que necesita el DNS
name del ALB, recién disponible ahora que se creó).

Al crearse, copia el **DNS name** del ALB (columna en la lista de Load
Balancers) — lo necesitas para todo lo que sigue. Se lo va a llamar
`<ALB_DNS>` en el resto de esta guía.

## 6. Certificado autofirmado + listener HTTPS del gateway

### 6.1 Generar el certificado (terminal)

```bash
ALB_DNS="<pega aquí el DNS name del ALB del paso 5.2>"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout alb-selfsigned.key \
  -out alb-selfsigned.crt \
  -days 365 \
  -subj "/CN=${ALB_DNS}" \
  -addext "subjectAltName=DNS:${ALB_DNS}"
```
Mismo patrón que `broker/rabbitmq/generate-lab-certs.sh` ya usa para el TLS
de RabbitMQ en este repo: certificado de laboratorio, autofirmado, con
`CN`/`SAN` apuntando al host real (acá, el DNS del ALB en vez de
`rabbitmq`).

### 6.2 Importar a ACM (consola)

**Certificate Manager (ACM) → Import a certificate**:
- Certificate body: pega el contenido de `alb-selfsigned.crt`
- Certificate private key: pega el contenido de `alb-selfsigned.key`
- Certificate chain: **vacío** (es autofirmado, no hay cadena intermedia)
- Import

Copia el **ARN** del certificado importado.

### 6.3 Agregar el listener HTTPS al ALB (consola)

**EC2 → Load Balancers → `security-app-alb` → pestaña Listeners → Add
listener**:
- Protocol: **HTTPS**
- Port: **8080**
- Default SSL/TLS certificate: **From ACM** → el certificado del paso 6.2
- Security policy: la recomendada por defecto
- Default action: forward a `security-app-gateway-tg`

En este punto ya existe `https://<ALB_DNS>:8080/` (va a dar 503 hasta que
el servicio `gateway` exista, paso 11) y `http://<ALB_DNS>/` (front, 503
hasta el paso 11 también).

## 7. Configurar OAuth real con Google

En [console.cloud.google.com](https://console.cloud.google.com) (o el
proyecto de GCP que ya tengas):

### 7.1 OAuth consent screen

**APIs & Services → OAuth consent screen**:
- User Type: **External**
- App name, User support email, Developer contact email: cualquier valor
  válido (es una demo, no necesita pasar revisión de Google)
- Scopes → **Add or remove scopes** → selecciona:
  - `openid`
  - `.../auth/userinfo.email`
  - `.../auth/userinfo.profile`
  (coinciden exactamente con lo que pide `gateway/src/auth.rs`)
- Test users → **Add users** → agrega la(s) cuenta(s) Gmail que van a hacer
  el login de la demo (**obligatorio**: mientras la app quede en estado
  "Testing" —lo normal para esto—, Google rechaza el login de cualquier
  cuenta que no esté en esta lista)

### 7.2 Crear el OAuth Client ID

**APIs & Services → Credentials → Create credentials → OAuth client ID**:
- Application type: **Web application**
- Name: cualquiera (ej. `security-app-demo`)
- Authorized redirect URIs → **Add URI**:
  ```
  https://<ALB_DNS>:8080/auth/callback
  ```
  (mismo `<ALB_DNS>` del paso 5.2, ahora con `https` — Google rechaza
  `http://` salvo `localhost`, por eso hizo falta el paso 6 antes que esto)
- Create

Google muestra un popup con el **Client ID** y el **Client secret** — cópialos, los vas a pegar en el paso 10 (task definition de `gateway`).

> **No los pegues de vuelta en `deploy/aws/task-defs/gateway.json` del
> repo** — ese archivo se queda con los placeholders `dev-placeholder` tal
> como está en git; los valores reales solo se pegan en el editor JSON de
> la consola de ECS al crear la task definition, para no dejar un secreto
> real committeado.

## 8. Build + push de `front`

```bash
cd security-app
docker build --build-arg VITE_GATEWAY_BASE_URL="https://<ALB_DNS>:8080" -t security-app/front ./front
docker tag security-app/front:latest <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/security-app/front:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/security-app/front:latest
```

Nota el `https` (no `http`): el listener 8080 del ALB pasó a ser HTTPS-only
en el paso 6, así que todas las llamadas de `front` al gateway deben usar
ese esquema — `VITE_GATEWAY_BASE_URL` se hornea en el bundle JS en
build-time (Vite) y en la CSP de nginx, no se puede fijar en runtime.

Si el ALB se recrea después (DNS distinto), hay que repetir el certificado
(paso 6), el registro en Google (paso 7, nuevo redirect URI) y este build,
y forzar un redeploy del servicio `front` (**ECS → Cluster → Services →
front → Update service → Force new deployment**).

## 9. Cluster ECS + namespace Service Connect + log groups

**ECS → Clusters → Create cluster**:
- Nombre: `security-app-cluster`
- Infrastructure: **AWS Fargate (serverless)**
- Networking: en el campo de **Namespace** del propio asistente, escribe
  `security-app.local` para que lo cree ECS.

**Importante si usas AWS Academy**: crea el namespace **siempre desde este
campo del asistente de cluster**, nunca por separado desde Cloud Map →
Namespaces → Create namespace. La identidad de estudiante de Academy
(`voclabs`) no tiene el permiso `servicediscovery:CreateHttpNamespace`, así
que crearlo directo en la consola de Cloud Map falla con `AccessDenied` —
pero cuando lo pides desde el asistente de ECS, es **ECS quien lo crea**
usando su propio service-linked role (que sí tiene ese permiso), no tu
usuario. Si ya creaste el cluster sin el namespace, bórralo y vuelve a
crearlo con el campo relleno — no se puede agregar después.

**CloudWatch → Log groups → Create log group**, 7 veces, con retención de 3
días, uno por servicio:
```
/ecs/security-app/postgres
/ecs/security-app/mongo
/ecs/security-app/rabbitmq
/ecs/security-app/user-service
/ecs/security-app/nmap-service
/ecs/security-app/gateway
/ecs/security-app/front
```
Se crean a mano porque la policy `AmazonECSTaskExecutionRolePolicy` no
incluye `logs:CreateLogGroup` — si no existen, la task falla al arrancar con
un error de log stream.

## 10. Las 7 task definitions (editor JSON de la consola)

**ECS → Task definitions → Create new task definition → Create new task
definition with JSON**. Para cada una de las 7:

1. Abre el archivo correspondiente en `deploy/aws/task-defs/` (`postgres.json`,
   `mongo.json`, `rabbitmq.json`, `user-service.json`, `nmap-service.json`,
   `gateway.json`, `front.json`).
2. Reemplaza a mano los placeholders antes de pegar:
   - `__EXEC_ROLE_ARN__` → el ARN del rol del paso 3.
   - `__AWS_REGION__` → tu región (ej. `us-east-1`).
   - `__IMG_POSTGRES__` → `public.ecr.aws/docker/library/postgres:16-alpine`
   - `__IMG_MONGO__` → `public.ecr.aws/docker/library/mongo:7`
   - `__IMG_RABBITMQ__`, `__IMG_USER_SERVICE__`, `__IMG_NMAP_SERVICE__`,
     `__IMG_GATEWAY__`, `__IMG_FRONT__` → los URIs completos que pusheaste
     en el paso 2/8 (`<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/security-app/<repo>:latest`).
   - `__GATEWAY_PUBLIC_URL__` (solo en `gateway.json`) →
     `https://<ALB_DNS>:8080` (con `https`, no `http`).
3. **Solo en `gateway.json`**: reemplaza además los valores de
   `GOOGLE_CLIENT_ID` y `GOOGLE_CLIENT_SECRET` (hoy `dev-placeholder`) por
   los reales que copiaste en el paso 7.2. Recuerda no guardar estos
   valores reales en el archivo del repo (ver nota del paso 7.2).
4. Pega el JSON ya con los valores reales en el editor y click **Create**.

Repite para las 7. Los campos `cpu`/`memory`/`portMappings`/`healthCheck`/
`environment`/`logConfiguration` ya vienen completos en cada JSON — no hay
que tocar nada más. Referencia rápida de qué hace cada una:

| Task definition | CPU/Mem | Puertos | Notas |
|---|---|---|---|
| postgres | 256/512 | 5432 | healthCheck `pg_isready` |
| mongo | 256/512 | 27017 | healthCheck `mongosh ping` |
| rabbitmq | 512/1024 | 5672, 5671, 15672 | sin env vars, todo horneado en la imagen |
| user-service | 256/512 | 8080 | sin healthCheck (distroless, sin shell) |
| nmap-service | 256/512 | (ninguno) | solo consumidor, sin healthCheck |
| gateway | 256/512 | 8080 | `GOOGLE_REDIRECT_URI`/`CLIENT_ID`/`CLIENT_SECRET` reales |
| front | 256/512 | 8080 | sin env vars (todo horneado en el bundle JS) |

## 11. Los 7 servicios ECS (en el mismo orden por tiers)

**ECS → Clusters → security-app-cluster → Service → Create**, para cada
servicio:
- Launch type: **FARGATE**
- Task definition: la que registraste en el paso 10 (usa siempre la última
  revisión)
- Service name: igual al nombre del compose (`postgres`, `mongo`,
  `rabbitmq`, `user-service`, `nmap-service`, `gateway`, `front`)
- Desired tasks: **1**
- Networking → VPC: la default; Subnets: las públicas; Security group:
  `security-app-internal-sg` (quita el "default"); Public IP: **Turned on**
  (la VPC default no tiene NAT, así que hasta las tasks "internas" necesitan
  IP pública para poder hacer pull de ECR — el aislamiento real lo dan los
  security groups, no la topología de red)

### 11.1 Tier 0 — `postgres`, `mongo`, `rabbitmq` (server-side Service Connect)

En la sección **Service Connect** del asistente de creación:
- Turn on Service Connect: **Sí**
- Namespace: `security-app.local`
- Para cada `portMapping` del container, agrega una entrada con:
  - `postgres`: Port name `postgres` → Discovery name `postgres`
  - `mongo`: Port name `mongo` → Discovery name `mongo`
  - `rabbitmq`: dos entradas — Port name `rabbitmq-amqp` → Discovery name
    `rabbitmq`, y Port name `rabbitmq-amqps` → Discovery name `rabbitmq`

Crea los 3 y espera a que su estado quede en **Running/Steady state**
(columna "Status" de la lista de servicios) antes de seguir al tier 1.

### 11.2 Tier 1 — `user-service`, `nmap-service`

- `user-service`: Service Connect **On**, namespace `security-app.local`,
  Port name `user-service` → Discovery name `user-service`.
- `nmap-service`: Service Connect **On**, namespace `security-app.local`,
  **sin ninguna entrada de puerto** (es puramente cliente: solo necesita
  resolver `mongo`/`rabbitmq` por DNS interno, no publica nada propio).

Espera a que ambos queden **Steady state**.

### 11.3 Tier 2 — `gateway`

- Service Connect **On**, namespace `security-app.local`, sin entradas de
  puerto propias (nadie le habla por DNS interno; solo lo público vía ALB).
- Sección **Load balancing**: **Application Load Balancer** →
  Load balancer: `security-app-alb` → Container: `gateway:8080` → Target
  group: **usar uno existente** → `security-app-gateway-tg`.

Espera a **Steady state**. Prueba: `curl -ik https://<ALB_DNS>:8080/health`.

### 11.4 Tier 3 — `front`

- **Sin** Service Connect (no necesita resolver nada por DNS interno; solo
  lo llama el navegador del usuario, vía la URL del ALB ya horneada en el
  bundle JS).
- Sección **Load balancing**: Load balancer `security-app-alb` → Container
  `front:8080` → Target group existente `security-app-front-tg`.

## 12. Verificación

```bash
ALB_DNS=<pega el DNS del ALB aquí>

# -k porque el cert del gateway es autofirmado (paso 6)
curl -ik "https://${ALB_DNS}:8080/health"                     # gateway, 200
curl -sk "https://${ALB_DNS}:8080/api/openapi.json" | head -c 300
curl -ik "https://${ALB_DNS}:8080/auth/login"                  # 302 hacia Google
curl -s -o /dev/null -w "%{http_code}\n" "http://${ALB_DNS}/"  # front, 200 (sin -k: sigue en HTTP plano)
```

Abre `http://<ALB_DNS>/` en el navegador — debe verse la pantalla de login.
Al iniciar sesión:
1. El navegador navega a `https://<ALB_DNS>:8080/auth/login` — aparece la
   advertencia "La conexión no es privada" (certificado autofirmado). Click
   en **Avanzado → Continuar**.
2. Redirige a Google, inicia sesión con una cuenta agregada como *test
   user* (paso 7.1) y acepta los permisos solicitados.
3. Google redirige de vuelta a `https://<ALB_DNS>:8080/auth/callback` —
   **misma advertencia otra vez**, mismo click.
4. Termina de vuelta en `front` con la cookie de sesión ya seteada
   (`gateway_session`, `HttpOnly`+`Secure`).

Esto es esperado y aceptado para esta demo (certificado de laboratorio, no
de una CA pública) — ver §1.3.

`user-service` no tiene target group (no debe exponerse a internet) —
verifícalo en **CloudWatch → Log groups → /ecs/security-app/user-service**.

Si algo falla:
1. **ECS → cluster → el service → pestaña "Events"** — eventos de scheduling
   (task no se pudo ubicar, target unhealthy, etc.).
2. **CloudWatch → Log groups → /ecs/security-app/<svc>** — logs de la
   aplicación (equivalente a `docker compose logs -f <svc>`).
3. **EC2 → Target Groups → <tg> → pestaña "Targets"** — estado de salud
   (`healthy`/`unhealthy`) para descartar problema de security group vs.
   problema de aplicación.
4. Si el login redirige pero nunca vuelve, o Google responde
   `Error 400: redirect_uri_mismatch` — revisa que el redirect URI del paso
   7.2 sea exactamente `https://<ALB_DNS>:8080/auth/callback` (mismo DNS,
   mismo puerto, sin barra final) y que `GOOGLE_REDIRECT_URI` en la task
   definition de `gateway` (paso 10) coincida.
5. Si Google responde `Error 403: access_denied` al loguear — la cuenta
   usada no está en la lista de *test users* del paso 7.1.

## 13. Cleanup (consola)

Para no dejar 7 tasks Fargate + 1 ALB facturando entre sesiones de
demo/entrega, borra en este orden:

1. **ECS → cluster → cada uno de los 7 services** → Update → Desired tasks
   a 0 → espera a que bajen → luego **Delete**.
2. **EC2 → Load Balancers** → borra `security-app-alb`.
3. **EC2 → Target Groups** → borra `security-app-front-tg` y
   `security-app-gateway-tg`.
4. **Certificate Manager (ACM)** → borra el certificado autofirmado
   importado en el paso 6.2.
5. **ECS → Clusters** → borra `security-app-cluster`.
6. **Cloud Map → Namespaces** → borra `security-app.local`.
7. **EC2 → Security Groups** → borra `security-app-internal-sg` y
   `security-app-alb-sg` (espera unos segundos tras el paso 1: no se pueden
   borrar hasta que las ENIs de las tasks se liberen).
8. **CloudWatch → Log groups** → borra los 7 `/ecs/security-app/*`.
9. **ECR → Repositories** → borra los 5 repos (`Force delete` si tienen
   imágenes).
10. **IAM → Roles** → borra `security-app-ecs-execution-role` **solo si lo
    creaste tú en el paso 3** (cuenta propia). Si usaste AWS Academy y
    reutilizaste `LabRole`, **no lo borres** — es de toda la cuenta, no
    algo que este despliegue creó.
11. **Google Cloud Console → APIs & Services → Credentials** → borra el
    OAuth client ID del paso 7.2 si no lo vas a reutilizar (opcional, no
    genera costo en AWS, pero es buena práctica no dejar credenciales
    vivas sin uso).
