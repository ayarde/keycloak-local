#!/usr/bin/env bash
#
# =============================================================================
# import-check.sh
#
# Valida realm/ecommerce-realm.json (sintaxis + estructura) y, de forma
# opcional, comprueba contra el Keycloak en ejecución que el realm se haya
# importado correctamente.
#
# Uso (desde la raíz del proyecto):
#   ./scripts/import-check.sh            # validación local del JSON
#   ./scripts/import-check.sh --online   # además verifica contra Keycloak
#
# Requisitos: python3 para la validación local; docker/curl para --online.
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REALM_FILE="$PROJECT_DIR/realm/ecommerce-realm.json"
REALM_NAME="ecommerce"

KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"

ONLINE=false
for arg in "$@"; do
  case "$arg" in
    --online) ONLINE=true ;;
    *) echo "Uso: $0 [--online]" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }

FAILURES=0
check() { # check <descripcion> <condicion>
  if [ "$2" = "true" ]; then
    ok "$1"
  else
    fail "$1"
    FAILURES=$((FAILURES + 1))
  fi
}

# ----------------------------------------------------------- validación ---
[ -f "$REALM_FILE" ] || { fail "No existe $REALM_FILE"; exit 1; }
info "Validando $REALM_FILE ..."

# Validación estructural con python3 (JSON bien formado + campos requeridos)
EVAL="$(python3 - "$REALM_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    d = json.load(fh)

checks = {
    "realm se llama 'ecommerce'": d.get("realm") == "ecommerce",
    "realm habilitado": d.get("enabled") is True,
}

roles = {r.get("name") for r in (d.get("roles") or {}).get("realm") or []}
for r in ("ADMIN", "CUSTOMER", "SELLER", "SUPPORT"):
    checks[f"rol realm '{r}' presente"] = r in roles

clients = {c.get("clientId"): c for c in d.get("clients") or []}
api = clients.get("ecommerce-api")
fnt = clients.get("ecommerce-frontend")

checks["cliente 'ecommerce-api' presente"] = api is not None
if api:
    checks["ecommerce-api es confidencial"] = api.get("publicClient") is False
    checks["ecommerce-api: client authentication"] = api.get("clientAuthenticatorType") == "client-secret" and bool(api.get("secret"))
    checks["ecommerce-api: standard flow"] = api.get("standardFlowEnabled") is True
    checks["ecommerce-api: direct access grants"] = api.get("directAccessGrantsEnabled") is True
    checks["ecommerce-api: service accounts"] = api.get("serviceAccountsEnabled") is True

checks["cliente 'ecommerce-frontend' presente"] = fnt is not None
if fnt:
    checks["ecommerce-frontend es público"] = fnt.get("publicClient") is True
    redirs = fnt.get("redirectUris") or []
    checks["ecommerce-frontend: redirect http://localhost:*"] = "http://localhost:*" in redirs
    checks["ecommerce-frontend: redirect http://localhost:4200/*"] = "http://localhost:4200/*" in redirs
    checks["ecommerce-frontend: web origins *"] = "*" in (fnt.get("webOrigins") or [])

expected = {
    "admin": "ADMIN",
    "customer1": "CUSTOMER",
    "seller1": "SELLER",
    "support1": "SUPPORT",
}
users = {u.get("username"): u for u in d.get("users") or []}
for username, role in expected.items():
    u = users.get(username)
    checks[f"usuario '{username}' presente"] = u is not None
    if u:
        creds = u.get("credentials") or []
        has_pass = any(c.get("type") == "password" and c.get("value") and c.get("temporary") is False for c in creds)
        checks[f"usuario '{username}' con password no temporal"] = has_pass
        checks[f"usuario '{username}' con rol '{role}'"] = role in (u.get("realmRoles") or [])

for name, passed in checks.items():
    print(("PASS\t" if passed else "FAIL\t") + name)
    if not passed:
        sys.stdout.flush()
PY
)"

if [ -z "$EVAL" ]; then
  fail "El archivo no es JSON válido."
  exit 1
fi

while IFS=$'\t' read -r status name; do
  check "$name" "$([ "$status" = "PASS" ] && echo true || echo false)"
done <<< "$EVAL"

if [ "$FAILURES" -gt 0 ]; then
  fail "Validación local: $FAILURES comprobación(es) fallida(s)."
  exit 1
fi
ok "Validación local completada sin errores."

# ------------------------------------------------------------ verificación online ---
if [ "$ONLINE" = true ]; then
  info "Verificando contra el Keycloak activo ($KC_URL) ..."
  command -v curl >/dev/null 2>&1 || fail "Se necesita 'curl' para --online."

  curl -fsS "$KC_URL/health/ready" >/dev/null 2>&1 \
    && ok "Keycloak responde en $KC_URL/health/ready" \
    || { fail "Keycloak no responde en $KC_URL/health/ready"; exit 1; }

  TOKEN="$(curl -fsS \
    -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN_USER" \
    -d "password=$KC_ADMIN_PASSWORD" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")" \
    || { fail "No se pudo autenticar como '$KC_ADMIN_USER'."; exit 1; }
  ok "Autenticado como '$KC_ADMIN_USER' (realm master)."

  REALM_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$KC_URL/admin/realms/$REALM_NAME")"
  if [ "$REALM_HTTP" = "200" ]; then
    ok "El realm '$REALM_NAME' existe en el servidor."
  else
    fail "El realm '$REALM_NAME' no se encontró (HTTP $REALM_HTTP). ¿Se importó? Revisa: docker compose logs keycloak"
    exit 1
  fi

  CLIENTS_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$KC_URL/admin/realms/$REALM_NAME/clients?clientId=ecommerce-api")"
  [ "$CLIENTS_HTTP" = "200" ] \
    && ok "El cliente 'ecommerce-api' está registrado en el servidor." \
    || fail "No se pudo consultar el cliente 'ecommerce-api' (HTTP $CLIENTS_HTTP)."

  ok "Verificación online completada."
fi

echo ""
ok "import-check finalizado."
