# Cómo levantar y probar `security-app`

Dos caminos: **AWS (Terraform)** y **local (docker compose)**.

## A. AWS Learner Lab con Terraform

El flujo completo (bucket de estado, namespace, `terraform apply`, push de
imágenes, cliente Google, verificación, pausa/resume, destroy) está en
[`terraform/README.md`](terraform/README.md#end-to-end-deploy), sección
"End-to-end deploy". Los scripts imperativos de `deploy/aws/` ya no existen.

Resumen: `scripts/bootstrap-state-bucket.sh` -> `scripts/bootstrap-namespace.sh`
-> `terraform -chdir=terraform apply` -> `scripts/push-images.sh` ->
`scripts/set-google-oauth.sh` -> `scripts/verify-stack.sh`.

### Google OAuth: pasos manuales (una sola vez)

En <https://console.cloud.google.com>:

1. APIs & Services -> OAuth consent screen
   - User Type: External
   - Scopes: `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile`
   - Test users: las cuentas Gmail que van a hacer login
2. APIs & Services -> Credentials -> Create credentials -> OAuth client ID
   - Application type: Web application
   - Authorized redirect URIs, EXACTO: salida de Terraform `gateway_public_url`
     (`terraform -chdir=terraform output -raw gateway_public_url`) + `/auth/callback`
   - Copia el Client ID y el Client secret.
3. Guárdalos en SSM y redeploya el gateway:
   `GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... scripts/set-google-oauth.sh`

El gateway usa un certificado autofirmado (sin dominio): el navegador avisa.
Si no pasas las variables, `set-google-oauth.sh` lee el archivo local sin
versionar `deploy/aws/.state/google_oauth.env` (gitignored; guarda ahí los
valores, nunca los commitees).

## B. Local con docker compose

Guía de arranque para los 5 servicios (`broker`, `user-service`, `nmap-service`,
`gateway`, `front`) vía `docker-compose.yml` en esta carpeta.

### 0. Prerrequisitos

- Docker + Docker Compose v2 (`docker compose version`).
- Certificados TLS de laboratorio del broker ya generados. Si
  `broker/rabbitmq/tls/` no existe o está vacío:
  ```bash
  ../broker/rabbitmq/generate-lab-certs.sh
  ```
  (Ahora mismo ya existen en este checkout — no hace falta correrlo salvo que
  se borren o se clone el repo en otra máquina.)

### 1. Levantar todo

```bash
docker compose up --build
```

Primera vez: compila 3 imágenes Rust (`user-service`, `nmap-service`,
`gateway`, todas multi-stage con toolchain completa) + la imagen de `front`
(Node + build de Vite) — puede tardar varios minutos. Corridas siguientes son
incrementales.

Para dejarlo en background: `docker compose up --build -d`, y ver logs con
`docker compose logs -f <servicio>`.

### 2. Qué verificar que subió bien

```bash
# RabbitMQ management UI (usuario lab-admin / lab-only-not-a-real-secret)
curl -i http://localhost:15672

# user-service
curl -i http://localhost:8081/health          # 200 si Postgres responde

# gateway
curl -i http://localhost:8080/health           # 200
curl -s http://localhost:8080/api/openapi.json | head -c 300   # superficie de la API

# nmap-service — queda escuchando el Broker (ver verificación en el log)
docker compose logs -f nmap-service
```

`docker compose ps` debe mostrar `nmap-service` en estado `Up` y
`docker compose logs nmap-service` **sin** errores del tipo
`no se pudo inicializar ms-nmap` ni `no se pudo conectar al Broker (AMQPS)`:
el contenedor queda **en ejecución** consumiendo de
`ms-nmap.scan-requests` (adaptador RabbitMQ real, feature `broker_adapter`
de `nmap-service`). Si aparece un fallo de conexión AMQPS, revisa que
`broker/rabbitmq/tls/` tenga los certificados (paso 0) — el `SSL_CERT_FILE`
del compose inyecta la CA de laboratorio al contenedor.

Front: abre `http://localhost:8082` en el navegador — debe verse la pantalla
de login.

### 3. Probar `user-service` directamente (sin pasar por login)

`user-service` nunca debe exponerse a internet en un despliegue real (solo el
Gateway le habla), pero para probarlo aislado en este compose puedes mandarle
tú mismo los headers que el Gateway le reenviaría:

- `X-Gateway-Secret`: debe coincidir con `GATEWAY_SHARED_SECRET` (`dev-shared-secret`).
- `X-Forwarded-User`: identidad ya verificada — **es un string plano opaco**
  (p. ej. `google-oauth2|123456`), no JSON.

```bash
# Crea el perfil del usuario "dev-user-1" (PUT es upsert)
curl -i http://localhost:8081/users/me \
  -X PUT \
  -H 'X-Gateway-Secret: dev-shared-secret' \
  -H 'X-Forwarded-User: dev-user-1' \
  -H 'Content-Type: application/json' \
  -d '{"email":"dev@example.test","display_name":"Dev User"}'

# Lo lee de vuelta
curl -s http://localhost:8081/users/me \
  -H 'X-Gateway-Secret: dev-shared-secret' \
  -H 'X-Forwarded-User: dev-user-1' | jq .

# Historial de escaneos (vacío al principio)
curl -s http://localhost:8081/users/me/scans \
  -H 'X-Gateway-Secret: dev-shared-secret' \
  -H 'X-Forwarded-User: dev-user-1' | jq .
```

Sin el header `X-Gateway-Secret` correcto → `401`. Sin `X-Forwarded-User` →
error tipado `MissingIdentity`.

> Nota técnica: el cliente HTTP de `gateway` (`usuarios_client.rs`) hoy
> serializa la identidad como **JSON** (`{"sub":"...","email":"..."}`) en ese
> mismo header, mientras que `user-service` la trata como **string plano**
> (usa el header entero como `user_id`). No es un problema para esta prueba
> manual (usamos el formato que `user-service` realmente espera), pero es una
> inconsistencia real entre ambos repos si se integran de verdad más adelante.

### 4. Ver el hueco 1 en vivo (envío de escaneo bloqueado)

```bash
curl -i http://localhost:8080/auth/login
```
Redirige (`302`) hacia Google con `GOOGLE_CLIENT_ID=dev-placeholder` — Google
responderá con un error porque el client no existe, pero confirma que el
wiring OIDC del lado de `gateway` está armado.

Sin una sesión válida no se puede probar `POST /api/scans` desde fuera del
navegador sin fabricar a mano un JWT firmado con `SESSION_SIGNING_KEY`
(claims `{sub, email, name, exp, aud, iss}`, HS256) — se deja fuera de esta
guía a propósito. Si más adelante quieres probar ese flujo sin credenciales
Google reales, la opción más limpia es un endpoint de dev-login en `gateway`
(mismo espíritu que `front/e2e/contract-server`, que ya hace esto para el
front) — es trabajo de feature aparte, no de esta guía.

### 5. Apagar / limpiar

```bash
docker compose down          # detiene y borra los contenedores
docker compose down -v       # además borra los volúmenes (Postgres/Mongo quedan vacíos la próxima vez)
```

### Huecos conocidos (por qué no hay un flujo completo login→escaneo→resultado)

1. **`gateway POST /api/scans` responde `501`.** El handler ya está
   implementado y llama a `user-service` para resolver
   `network_user`/`ssh_credentials_ref`/`has_sudo`, pero **`user-service`
   todavía no implementa esa API** (0 referencias a esos campos en su
   código). El propio OpenAPI de `gateway` documenta el `501` explícitamente.
2. **~`nmap-service` no consumía del Broker — ya cerrado con la feature
   `broker_adapter` de `nmap-service`~.** `ms-nmap` ahora se conecta por AMQPS
   (`RabbitMqScanRequestSource`/`RabbitMqScanCancellationSource`/
   `RabbitMqScanResultSink`) y queda escuchando `ms-nmap.scan-requests`/
   `ms-nmap.scan-cancellations`. Para que funcione en este compose se monta la
   CA de laboratorio y se fija `SSL_CERT_FILE` (ver el bloque `nmap-service`).
   El flujo completo sigue bloqueado por el hueco 1 (sin `POST /api/scans`
   funcional en `gateway` no hay `ScanRequest` que publicar).
3. **Sin login real.** Sin `GOOGLE_CLIENT_ID`/`SECRET` reales (registrados en
   Google Cloud Console con el `GOOGLE_REDIRECT_URI` correspondiente) no se
   puede completar el flujo OIDC por navegador. No hay IdP mock utilizable a
   mano en este repo.

Cerrar el hueco 1 es trabajo de feature en `user-service` (API de credenciales
de red) — mismo flujo `AGENTS.md`/`feature_list.json` que se usó para el resto
de cada repo. El hueco 2 ya está cerrado (adaptador RabbitMQ real de
`nmap-service`).
