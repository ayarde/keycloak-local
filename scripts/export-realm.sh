#!/usr/bin/env bash
#
# =============================================================================
# export-realm.sh
#
# Exporta el realm "ecommerce" del Keycloak en ejecución y SOBRESCRIBE
# realm/ecommerce-realm.json con la exportación más completa posible.
#
# ¿Por qué se detiene Keycloak unos segundos?
#   - En Keycloak 26 el comando `kcadm.sh export` fue ELIMINADO.
#   - La exportación por Admin REST API (partial-export) NO incluye usuarios
#     ni secretos de clientes -> el archivo resultante no es restaurable.
#   - La exportación offline `kc.sh export --users realm_file` SÍ incluye
#     usuarios (con sus hashes de contraseña) y el secreto de los clientes,
#     por lo que el archivo sirve como backup real.
#   - Esta exportación offline exige que el servidor esté detenido, por lo
#     que el script para el contenedor de Keycloak, exporta y lo vuelve a
#     arrancar automáticamente (incluso si algo falla).
#
# Uso (desde la raíz del proyecto):
#   ./scripts/export-realm.sh
#
# Requisitos: el entorno debe estar levantado (docker compose up -d).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- config ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
REALM_DIR="$PROJECT_DIR/realm"
REALM_FILE="$REALM_DIR/ecommerce-realm.json"
REALM_NAME="ecommerce"

# ------------------------------------------------------------- utilidades ---
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# Detecta "docker compose" (v2) o "docker-compose" (v1)
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fail "No se encontró 'docker compose'. Instala Docker Compose y reintenta."
fi

# Devuelve el valor de una variable de entorno del contenedor
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" \
    | sed -n "s/^$2=//p"
}

# ----------------------------------------------------------------- checks ---
command -v docker >/dev/null 2>&1 || fail "No se encontró 'docker' en el PATH."
docker info >/dev/null 2>&1 || fail "Docker no está en ejecución. Arranca Docker (o OrbStack) y reintenta."

KC_ID="$("${COMPOSE[@]}" -f "$COMPOSE_FILE" ps -q keycloak)"
[ -n "$KC_ID" ] || fail "No existe el contenedor de Keycloak. Levanta primero: docker compose up -d"
[ "$(docker inspect -f '{{.State.Running}}' "$KC_ID")" = "true" ] \
  || fail "Keycloak no está en ejecución. Arranca el entorno: docker compose up -d"

PG_ID="$("${COMPOSE[@]}" -f "$COMPOSE_FILE" ps -q postgres)"
[ -n "$PG_ID" ] || fail "No existe el contenedor de PostgreSQL. Levanta primero: docker compose up -d"
[ "$(docker inspect -f '{{.State.Running}}' "$PG_ID")" = "true" ] \
  || fail "PostgreSQL no está en ejecución. Arranca el entorno: docker compose up -d"

# Hereda imagen y conexión a BD del contenedor en ejecución (nunca se desincronizan)
KC_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$KC_ID")"
NETWORK="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$KC_ID" | awk '{print $1}')"
DB_URL="$(container_env "$KC_ID" KC_DB_URL)"
DB_USERNAME="$(container_env "$KC_ID" KC_DB_USERNAME)"
DB_PASSWORD="$(container_env "$KC_ID" KC_DB_PASSWORD)"

[ -n "$KC_IMAGE" ]   || fail "No se pudo obtener la imagen de Keycloak del contenedor."
[ -n "$NETWORK" ]    || fail "No se pudo obtener la red Docker del proyecto."
[ -n "$DB_URL" ]     || fail "No se pudo obtener KC_DB_URL del contenedor de Keycloak."
[ -n "$DB_USERNAME" ] || fail "No se pudo obtener KC_DB_USERNAME del contenedor de Keycloak."
[ -n "$DB_PASSWORD" ] || fail "No se pudo obtener KC_DB_PASSWORD del contenedor de Keycloak."

info "Realm a exportar : $REALM_NAME"
info "Imagen de Keycloak: $KC_IMAGE"
info "Red Docker        : $NETWORK"
info "Archivo de salida : $REALM_FILE"

# ------------------------------------------------- reinicio automático ---
# Garantiza que Keycloak vuelva a arrancar aunque el export falle
KC_STOPPED=false
restart_keycloak() {
  if [ "$KC_STOPPED" = true ]; then
    info "Reiniciando Keycloak..."
    if "${COMPOSE[@]}" -f "$COMPOSE_FILE" start keycloak >/dev/null 2>&1; then
      ok "Keycloak reiniciado de nuevo."
      KC_STOPPED=false
    else
      warn "No se pudo reiniciar Keycloak automáticamente. Ejecuta: docker compose start"
    fi
  fi
}
trap restart_keycloak EXIT

# -------------------------------------------------------------- exportar ---
warn "Se detendrá Keycloak unos segundos para realizar un backup consistente."
"${COMPOSE[@]}" -f "$COMPOSE_FILE" stop keycloak >/dev/null
KC_STOPPED=true
ok "Keycloak detenido."

EXPORT_DIR="/opt/keycloak/data/export"
# Misma configuración build-time que el servidor en ejecución (evita recompilar)
info "Exportando realm '$REALM_NAME' (con usuarios y secretos)..."
docker run --rm \
  --network "$NETWORK" \
  -e "KC_DB=postgres" \
  -e "KC_DB_URL=$DB_URL" \
  -e "KC_DB_USERNAME=$DB_USERNAME" \
  -e "KC_DB_PASSWORD=$DB_PASSWORD" \
  -e "KC_HEALTH_ENABLED=true" \
  -e "KC_HTTP_MANAGEMENT_HEALTH_ENABLED=false" \
  -v "$REALM_DIR:$EXPORT_DIR" \
  "$KC_IMAGE" \
  export --dir "$EXPORT_DIR" --realm "$REALM_NAME" --users realm_file

restart_keycloak

# ---------------------------------------------------------------- validar ---
[ -f "$REALM_FILE" ] || fail "No se generó el archivo $REALM_FILE"

python3 - "$REALM_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

assert data.get("realm") == "ecommerce", "el realm exportado no es 'ecommerce'"
users = data.get("users") or []
clients = data.get("clients") or []
print(f"users={len(users)} clients={len(clients)}")
if not users:
    print("WARN_NO_USERS")
PY

if python3 -c "import json,sys; sys.exit(0 if not (json.load(open('$REALM_FILE')).get('users') or []) else 1)"; then
  warn "El export no contiene usuarios (¿se importó el realm con usuarios?)."
fi

ok "Backup completado: $REALM_FILE"
