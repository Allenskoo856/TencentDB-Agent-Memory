#!/bin/sh
set -eu

# This is a target-runtime smoke test, not a build test. It deliberately runs
# the four already-built images without a network namespace and without root.
# A Debian 10 control container supplies the buster userspace compatibility
# check used by the GitHub-hosted validation job.

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)

debian_image=${DEBIAN_IMAGE:-debian:10}
runtime_uid=${RUNTIME_UID:-10001}
runtime_gid=${RUNTIME_GID:-10001}
smoke_timeout_seconds=${SMOKE_TIMEOUT_SECONDS:-150}

core_image=${CORE_IMAGE:-tdai-memory-core:intranet}
knowledge_image=${KNOWLEDGE_IMAGE:-tdai-memory-knowledge:intranet}
panel_image=${PANEL_IMAGE:-tdai-memory-panel:intranet}
proxy_image=${PROXY_IMAGE:-tdai-memory-proxy:intranet}

case "$runtime_uid" in
  ''|*[!0-9]*) echo "RUNTIME_UID must be numeric" >&2; exit 2 ;;
esac
case "$runtime_gid" in
  ''|*[!0-9]*) echo "RUNTIME_GID must be numeric" >&2; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || {
  echo "docker is required" >&2
  exit 2
}

container_prefix="tdai-debian10-smoke-$$"
core_container="${container_prefix}-core"
knowledge_container="${container_prefix}-knowledge"
panel_container="${container_prefix}-panel"
proxy_container="${container_prefix}-proxy"

cleanup() {
  docker rm -f \
    "$core_container" \
    "$knowledge_container" \
    "$panel_container" \
    "$proxy_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

require_image() {
  image=$1
  docker image inspect "$image" >/dev/null 2>&1 || {
    echo "image is not available locally: $image" >&2
    exit 1
  }
  platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
  echo "[OK] image available: $image ($platform)"
}

check_image_user() {
  image=$1
  docker run --rm \
    --network none \
    --user "$runtime_uid:$runtime_gid" \
    --entrypoint /bin/sh \
    "$image" \
    -eu -c '
      test "$(id -u)" = "$1"
      test "$(id -g)" = "$2"
    ' -- "$runtime_uid" "$runtime_gid"
  echo "[OK] non-root runtime identity: $image ($runtime_uid:$runtime_gid)"
}

echo "Checking Debian 10 userspace and ordinary runtime identity"
docker pull "$debian_image" >/dev/null
docker run --rm \
  --network none \
  --user "$runtime_uid:$runtime_gid" \
  "$debian_image" \
  sh -eu -c '
    version=$(cat /etc/debian_version)
    case "$version" in
      10.*) ;;
      *) echo "expected Debian 10, got $version" >&2; exit 1 ;;
    esac
    test "$(id -u)" = "$1"
    test "$(id -g)" = "$2"
  ' -- "$runtime_uid" "$runtime_gid"
echo "[OK] Debian 10 control container: $debian_image"

require_image "$core_image"
require_image "$knowledge_image"
require_image "$panel_image"
require_image "$proxy_image"

check_image_user "$core_image"
check_image_user "$knowledge_image"
check_image_user "$panel_image"
check_image_user "$proxy_image"

start_core() {
  docker run -d \
    --name "$core_container" \
    --network none \
    --user "$runtime_uid:$runtime_gid" \
    --tmpfs "/data/tdai-memory:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    --tmpfs "/tmp:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    -v "$repo_root/deploy/intranet/config/tdai-gateway.yaml:/data/config/tdai-gateway.yaml:ro" \
    -e TDAI_GATEWAY_API_KEY=ci-gateway-key \
    -e TDAI_LLM_BASE_URL=http://127.0.0.1:9/v1 \
    -e TDAI_LLM_API_KEY=ci-llm-key \
    -e TDAI_LLM_MODEL=ci-smoke-model \
    -e TDAI_GATEWAY_CONFIG=/data/config/tdai-gateway.yaml \
    "$core_image" >/dev/null
}

start_knowledge() {
  docker run -d \
    --name "$knowledge_container" \
    --network none \
    --user "$runtime_uid:$runtime_gid" \
    --tmpfs "/app/data:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    --tmpfs "/tmp:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    -e NODE_ENV=production \
    -e PORT=8421 \
    -e API_PREFIX=/v3 \
    -e KNOWLEDGE_DATA_DIR=/app/data \
    -e KNOWLEDGE_DB_PATH=/app/data/knowledge.db \
    -e KNOWLEDGE_PUBLIC_BASE_URL=http://127.0.0.1:8421/v3 \
    -e TMC_CALLBACK_URL=http://127.0.0.1:9 \
    -e LLM_MODE=custom \
    -e LLM_PROTOCOL=openai \
    -e LLM_PROVIDER=intranet \
    -e LLM_BASE_URL=http://127.0.0.1:9/v1 \
    -e LLM_API_KEY=ci-llm-key \
    -e LLM_MODEL=ci-smoke-model \
    -e LLM_MAX_TOKENS=1024 \
    -e LLM_TIMEOUT_MS=1000 \
    "$knowledge_image" >/dev/null
}

start_panel() {
  docker run -d \
    --name "$panel_container" \
    --network none \
    --user "$runtime_uid:$runtime_gid" \
    --tmpfs "/tmp:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    -v "$repo_root/deploy/intranet/config/metadata-instances.template.json:/run/config/metadata-instances.template.json:ro" \
    -e NODE_ENV=production \
    -e HOST=0.0.0.0 \
    -e PORT=8123 \
    -e TDAI_GATEWAY_API_KEY=ci-gateway-key \
    -e TDAI_PROXY_PUBLIC_URL=http://127.0.0.1:8096 \
    -e METADATA_INSTANCES_TEMPLATE=/run/config/metadata-instances.template.json \
    -e METADATA_INSTANCES_CONFIG=/tmp/metadata-instances.json \
    -e KNOWLEDGE_SERVICE_URL=http://127.0.0.1:9 \
    -e KNOWLEDGE_LLM_PROXY_BASE_URL=http://127.0.0.1:9 \
    -e KNOWLEDGE_LLM_BINDING_SYNC=false \
    "$panel_image" >/dev/null
}

start_proxy() {
  docker run -d \
    --name "$proxy_container" \
    --network none \
    --user "$runtime_uid:$runtime_gid" \
    --tmpfs "/data/tdai-memory-proxy:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    --tmpfs "/tmp:rw,exec,uid=$runtime_uid,gid=$runtime_gid" \
    -v "$repo_root/deploy/intranet/config/proxy.yaml:/data/config.yaml:ro" \
    -e NODE_ENV=production \
    -e PROXY_DB_PATH=/data/tdai-memory-proxy/proxy.db \
    -e TDAI_GATEWAY_API_KEY=ci-gateway-key \
    -e TDAI_PROXY_AUTH_API_KEY=ci-gateway-key \
    -e INTRANET_LLM_BASE_URL=http://127.0.0.1:9/v1 \
    -e INTRANET_LLM_API_KEY=ci-llm-key \
    -e TDAI_PROXY_PUBLIC_URL=http://127.0.0.1:8096 \
    "$proxy_image" >/dev/null
}

wait_healthy() {
  name=$1
  label=$2
  elapsed=0
  while [ "$elapsed" -lt "$smoke_timeout_seconds" ]; do
    state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)
    case "$health" in
      healthy)
        echo "[OK] $label healthy after ${elapsed}s"
        return 0
        ;;
      unhealthy)
        echo "[ERROR] $label became unhealthy" >&2
        docker logs --tail 200 "$name" >&2 || true
        return 1
        ;;
    esac
    if [ "$state" = exited ] || [ "$state" = dead ]; then
      echo "[ERROR] $label exited before becoming healthy" >&2
      docker logs --tail 200 "$name" >&2 || true
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "[ERROR] timed out waiting for $label (${smoke_timeout_seconds}s)" >&2
  docker inspect "$name" >&2 || true
  docker logs --tail 200 "$name" >&2 || true
  return 1
}

echo "Starting the four images with --network none and $runtime_uid:$runtime_gid"
start_core
start_knowledge
start_panel
start_proxy

wait_healthy "$core_container" memory-core
wait_healthy "$knowledge_container" memory-knowledge
wait_healthy "$panel_container" memory-panel
wait_healthy "$proxy_container" memory-proxy

echo "Debian 10/UOS-compatible no-network startup smoke passed"
