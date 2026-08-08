#!/bin/sh
set -eu

base_url="${TDAI_BOOTSTRAP_URL:-http://memory-core:8420}"
api_key="${TDAI_GATEWAY_API_KEY:?TDAI_GATEWAY_API_KEY is required}"
user_key="${TDAI_ADMIN_USER_KEY:?TDAI_ADMIN_USER_KEY is required}"
username="${TDAI_ADMIN_USERNAME:-admin}"
instance_id="${TDAI_INSTANCE_ID:-default}"

body=$(printf '{"username":"%s","user_key":"%s"}' "$username" "$user_key")
response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

code="000"
i=0
while [ "$i" -lt 30 ]; do
  code=$(curl --silent --show-error --max-time 5 \
    -o "$response_file" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $api_key" \
    -H "x-tdai-service-id: $instance_id" \
    -H 'Content-Type: application/json' \
    "$base_url/v3/internal/meta/user/init-admin" \
    -d "$body" || true)
  case "$code" in
    2??|409)
      echo "core admin bootstrap accepted (HTTP $code)"
      exit 0
      ;;
  esac
  i=$((i + 1))
  sleep 2
done

echo "core admin bootstrap failed (HTTP $code)" >&2
sed -n '1,120p' "$response_file" >&2 || true
exit 1
