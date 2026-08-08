#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
deploy_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$deploy_dir"

compose_env_value() {
  key="$1"
  docker compose config --environment 2>/dev/null | awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}'
}

bind_address=$(compose_env_value INTRANET_BIND_ADDRESS)
case "$bind_address" in
  ""|0.0.0.0|::) bind_address=127.0.0.1 ;;
esac

core_port=$(compose_env_value CORE_HOST_PORT); core_port=${core_port:-8420}
panel_port=$(compose_env_value PANEL_HOST_PORT); panel_port=${panel_port:-8125}
knowledge_port=$(compose_env_value KNOWLEDGE_HOST_PORT); knowledge_port=${knowledge_port:-8424}
proxy_port=$(compose_env_value PROXY_HOST_PORT); proxy_port=${proxy_port:-8096}
gateway_key=$(compose_env_value TDAI_GATEWAY_API_KEY)
admin_key=$(compose_env_value TDAI_ADMIN_USER_KEY)
instance_id=$(compose_env_value TDAI_INSTANCE_ID); instance_id=${instance_id:-default}

require_http_ok() {
  label="$1"
  url="$2"
  curl --fail --silent --show-error "$url" >/dev/null
  echo "[OK] $label: $url"
}

require_http_ok "core health" "http://${bind_address}:${core_port}/health"
require_http_ok "knowledge health" "http://${bind_address}:${knowledge_port}/health"
require_http_ok "panel health" "http://${bind_address}:${panel_port}/health"
require_http_ok "proxy health" "http://${bind_address}:${proxy_port}/health"

if [ -z "$gateway_key" ] || [ -z "$admin_key" ]; then
  echo "[ERROR] TDAI_GATEWAY_API_KEY and TDAI_ADMIN_USER_KEY must be present in .env" >&2
  exit 1
fi

verify_file=$(mktemp)
trap 'rm -f "$verify_file"' EXIT
verify_code=$(curl --silent --show-error --max-time 10 \
  -o "$verify_file" -w '%{http_code}' \
  -X POST "http://${bind_address}:${core_port}/v3/meta/auth/verify" \
  -H "Authorization: Bearer $gateway_key" \
  -H "x-tdai-service-id: $instance_id" \
  -H 'Content-Type: application/json' \
  -d "{\"user_key\":\"$admin_key\"}")
if [ "$verify_code" != 200 ]; then
  echo "[ERROR] core auth/verify returned HTTP $verify_code" >&2
  sed -n '1,80p' "$verify_file" >&2 || true
  exit 1
fi
echo "[OK] core Bearer + admin user_key verification"

# Invalid user_key must be rejected before the proxy reaches the LLM.
proxy_code=$(curl --silent --show-error --max-time 10 \
  -o /dev/null -w '%{http_code}' \
  -X POST "http://${bind_address}:${proxy_port}/codebuddy/${instance_id}/v1/chat/completions" \
  -H 'Authorization: Bearer definitely-invalid-user-key' \
  -H 'Content-Type: application/json' \
  -d '{"model":"health-boundary","messages":[]}' || true)
if [ "$proxy_code" != 401 ]; then
  echo "[ERROR] proxy invalid-key boundary returned HTTP $proxy_code (expected 401)" >&2
  exit 1
fi
echo "[OK] proxy invalid user_key boundary: HTTP 401"

docker compose ps
echo "intranet deployment verification passed"
