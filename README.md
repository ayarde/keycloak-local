# keycloak-local

Entorno local de **Keycloak 26.x + PostgreSQL 16** con un realm de ejemplo
(`ecommerce`) que se importa automáticamente al levantar, listo para desarrollo
de microservicios y frontends.

## Estructura

```
keycloak-local/
├── docker-compose.yml        # Postgres + Keycloak con importación automática
├── realm/
│   └── ecommerce-realm.json  # Configuración del realm (fuente de verdad)
├── scripts/
│   ├── export-realm.sh       # Backup del realm actual → realm/ecommerce-realm.json
│   └── import-check.sh       # Valida el JSON y, opcionalmente, el servidor
├── .gitignore
└── README.md
```

## Requisitos

- Docker (con el plugin Compose v2) o Docker Compose v1.
- `python3` (macOS/Linux) y `curl` solo para las comprobaciones de los scripts.

## Levantar el entorno

```bash
docker compose up -d
```

En el primer arranque, Keycloak importa `realm/ecommerce-realm.json` desde
`/opt/keycloak/data/import` (montado de `./realm`). La importación puede
tardar unos segundos:

```bash
docker compose logs -f keycloak
```

Verás una línea como `import finished successfully` cuando termine.

## Acceso

| Recurso                | URL                                    | Credenciales |
|------------------------|----------------------------------------|--------------|
| Consola de Keycloak    | http://localhost:8080/admin/master/console/ | `admin` / `admin` |
| PostgreSQL (localhost) | `127.0.0.1:5432` (db `keycloak`)       | `keycloak` / `keycloak` |

> `http://localhost:8080/admin` redirige a la consola de arriba.
> Los puertos solo se publican en `127.0.0.1` (no se exponen a la red externa).

### Ver clientes y usuarios en la consola (paso a paso)

La consola abre por defecto en el realm **`master`**; los clientes y usuarios
del proyecto están en el realm **`ecommerce`**. Para verlos:

1. Abre http://localhost:8080/admin/master/console/ e inicia sesión con
   `admin` / `admin`.
2. Cambia de realm: desplegable arriba a la izquierda (dice "master") →
   selecciona **`ecommerce`**.
3. En el menú lateral:
   - **Clients** → verás `ecommerce-api` y `ecommerce-frontend`.
   - **Users** → verás `admin`, `customer1`, `seller1` y `support1`.

Enlaces directos (routing por hash de la consola):

- Clientes: http://localhost:8080/admin/master/console/#/ecommerce/clients
- Usuarios: http://localhost:8080/admin/master/console/#/ecommerce/users

> Si un enlace se queda cargando: recarga con **Cmd+Shift+R** o abre una
> ventana de incógnito (la SPA cachea y una URL/sesión antigua puede dejarla
> colgada).

### Usuarios de prueba (realm `ecommerce`)

| Username   | Password      | Rol       |
|------------|---------------|-----------|
| admin      | `admin123`    | ADMIN     |
| customer1  | `customer123` | CUSTOMER  |
| seller1    | `seller123`   | SELLER    |
| support1   | `support123`  | SUPPORT   |

### Clientes

| Cliente               | Tipo          | Uso                        |
|-----------------------|---------------|----------------------------|
| `ecommerce-api`       | Confidencial  | Microservicios (client credentials / direct access) |
| `ecommerce-frontend`  | Público       | Frontend (Angular u otro)  |

> Nota de seguridad: `ecommerce-api` usa *partial scope* (`fullScopeAllowed: false`)
> con los 4 roles del realm declarados en su alcance (`scopeMappings`). Su service
> account **no tiene roles asignados**, por lo que los tokens machine-to-machine
> llevan **solo scopes** (`catalog:read` / `catalog:write`), nunca roles. Un humano
> que autentica con este cliente (password grant, solo dev) sí ve sus roles en
> `realm_access.roles`. El frontend mantiene `fullScopeAllowed: true` (la SPA
> necesita los roles del usuario para la UI).

## Obtener tokens (ejemplos)

Endpoint de tokens (OpenID Connect):
`http://localhost:8080/realms/ecommerce/protocol/openid-connect/token`

> Los `access_token` de este realm duran **300 s (5 min)** (`expires_in: 300`).

### 1. Password grant (usuario + contraseña)

Con el cliente confidencial `ecommerce-api` (el único con *Direct Access Grants*
habilitado) y un usuario de prueba:

```bash
curl -s -X POST http://localhost:8080/realms/ecommerce/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=ecommerce-api" \
  -d "client_secret=you-api-client-secret-2026-Xy7k9Qz3W" \
  -d "username=customer1" \
  -d "password=customer123" \
  -d "scope=openid"
```

La respuesta incluye `access_token`, `refresh_token` y `expires_in`.

> `grant_type=password` está pensado **solo para probar en local** (dev). El
> frontend (`ecommerce-frontend`) tiene *Direct Access Grants* deshabilitado y usa
> authorization code + PKCE (sección 3); nunca uses password grant desde un
> navegador.

### 2. Client credentials (service account)

Para microservicios, con el cliente confidencial `ecommerce-api`:

```bash
curl -s -X POST http://localhost:8080/realms/ecommerce/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=ecommerce-api" \
  -d "client_secret=you-api-client-secret-2026-Xy7k9Qz3W"
```

El `access_token` resultante trae los scopes `catalog:read` y `catalog:write`
(además de `profile`/`email`/`roles`) y el claim `aud` incluye `catalog-service`
(client scopes `catalog:read`, `catalog:write` y `aud-catalog-service`, todos
default en el cliente). Es el flujo **machine-to-machine** para `catalog-service`:
con esos scopes puede leer y escribir (`GET` y `POST/PUT/DELETE/PATCH
/api/v1/products/**`); un token de máquina sin `catalog:write` responde **403**
en las escrituras.

### 3. Authorization code + PKCE (navegador / frontend)

Flujo para el frontend: genera un `code_verifier` (PKCE, `S256`), calcula su
`code_challenge` y redirige el navegador a:

```
http://localhost:8080/realms/ecommerce/protocol/openid-connect/auth?client_id=ecommerce-frontend&response_type=code&scope=openid&code_challenge_method=S256&code_challenge=<CHALLENGE>&redirect_uri=http://localhost:4200/callback
```

El usuario se autentica y Keycloak redirige a `redirect_uri` con `?code=...`. El
frontend intercambia ese `code` por tokens llamando al endpoint de tokens con
`grant_type=authorization_code`, `code_verifier` y el mismo `redirect_uri`.

> `redirect_uri` debe coincidir con las registradas en el cliente
> (`http://localhost:4200/*`). El token de este flujo también lleva `aud` con
> `catalog-service` (el scope `aud-catalog-service` es default en el cliente),
> requisito de `catalog-service`.

### 4. Guardar el token y decodificar su contenido

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/realms/ecommerce/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=ecommerce-api" \
  -d "client_secret=you-api-client-secret-2026-Xy7k9Qz3W" \
  -d "username=customer1" \
  -d "password=customer123" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

echo "$TOKEN"

# Decodificar el payload del JWT (sin validar la firma)
python3 -c "import base64,json,sys;t=sys.argv[1].split('.')[1];t+='='*(-len(t)%4);print(json.dumps(json.loads(base64.urlsafe_b64decode(t)),indent=2))" "$TOKEN"
```

Verás `preferred_username` y los roles en `realm_access.roles` (ej. `CUSTOMER`),
y el claim `aud` con `catalog-service`.

### 5. Token contra la Admin REST API

Para llamadas administrativas usa un token de un usuario con permisos (el admin
del realm master) con el cliente público `admin-cli`:

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=admin" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

# Listar usuarios del realm ecommerce
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/admin/realms/ecommerce/users

# Listar clientes del realm ecommerce
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/admin/realms/ecommerce/clients
```

## Comprobar el realm (import-check)

```bash
./scripts/import-check.sh            # valida realm/ecommerce-realm.json
./scripts/import-check.sh --online   # además verifica contra el Keycloak activo
```

## Backup / exportación (export-realm.sh)

```bash
./scripts/export-realm.sh
```

Este script **detiene Keycloak unos segundos**, exporta el realm completo
(usuarios con sus hashes de contraseña, roles, clientes **con sus secretos** y
grupos) usando la exportación offline `kc.sh export --users realm_file`, y
**sobrescribe `realm/ecommerce-realm.json`**. Keycloak se reinicia
automáticamente (aunque algo falle).

### ¿Por qué se usa la exportación offline?

- En Keycloak 26 se **eliminó** `kcadm.sh export`.
- La exportación por la Admin REST API (`partial-export`) y por la Admin
  Console **no incluye usuarios ni secretos de clientes**, así que el archivo
  resultante no es restaurable.
- `kc.sh export` (offline) es la única que captura todo y exige el servidor
  detenido, por lo que el script lo detiene/arranca por ti.

## Flujo de trabajo con `realm/ecommerce-realm.json`

Este archivo es la **fuente de verdad** de la configuración del realm, y a la
vez el destino de los backups.

1. **Edita el JSON** y reinicia para aplicarlo, **o**
2. **Cambia cosas en la consola** y ejecuta `./scripts/export-realm.sh` para
   volcarlas de vuelta al archivo.

**Importante:** `--import-realm` **omite** la importación si el realm ya existe
(para no pisar estado entre reinicios). Por tanto, para aplicar cambios del
JSON a un entorno ya iniciado tienes tres opciones:

- **Reset total** (borra BD y reimporta desde cero) — ver abajo.
- **Partial import** desde la consola: *Realm settings → Action → Partial
  import* (opciones `Skip` / `Overwrite`).
- **Borrar solo el realm** y reiniciar Keycloak (`docker compose restart
  keycloak`) para forzar la reimportación.

> Advertencia: el archivo exportado contiene el **secreto del cliente
> `ecommerce-api`** y los hashes de contraseña. Es un proyecto de desarrollo,
> pero evita compartir el repositorio si contiene este archivo.

## Resetear todo (volúmenes incluidos)

```bash
docker compose down -v
```

Este comando elimina contenedores **y el volumen de PostgreSQL**, de modo que
el siguiente `docker compose up -d` levanta el entorno limpio y vuelve a
importar el realm desde el JSON.

## Notas importantes

- **Versión**: la imagen está fijada a `quay.io/keycloak/keycloak:26.7.0`
  (rama 26.x). Para actualizar, cambia el tag en `docker-compose.yml`.
- **Persistencia**: los datos viven en el volumen `postgres_data`. `docker
  compose down` (sin `-v`) conserva los datos; `down -v` los borra.
- **Configuración sin `.env`**: los valores van directamente en
  `docker-compose.yml` por simplicidad.
- Los scripts asumen que se ejecutan desde la raíz del proyecto y que el
  entorno está levantado (`docker compose up -d`).

## Referencias

- [Importar y exportar realms (Keycloak)](https://www.keycloak.org/server/importExport)
- [Imagen de contenedor de Keycloak](https://www.keycloak.org/server/containers)
