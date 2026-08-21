#!/bin/sh
set -eu

# Package already-built images and secret-free intranet deployment files into
# a self-contained Docker offline medium. The build host may need approved
# APT/npm mirrors; the resulting target medium does not need network.

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
out_dir=${1:-$repo_root/artifacts}
mkdir -p "$out_dir"
out_dir=$(CDPATH= cd -- "$out_dir" && pwd)

source_commit=${SOURCE_COMMIT:-$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)}
source_branch=${SOURCE_BRANCH:-$(git -C "$repo_root" symbolic-ref --short -q HEAD 2>/dev/null || echo unknown)}
target_platform=${TARGET_PLATFORM:-linux/amd64}
media_name=${MEDIA_NAME:-tdai-memory-intranet-offline-${source_commit}}
debian_image=${DEBIAN_IMAGE:-debian:10}
include_debian_image=${INCLUDE_DEBIAN_IMAGE:-0}

case "$include_debian_image" in
  0|1) ;;
  *) echo "INCLUDE_DEBIAN_IMAGE must be 0 or 1" >&2; exit 2 ;;
esac

core_image=${CORE_IMAGE:-tdai-memory-core:intranet}
knowledge_image=${KNOWLEDGE_IMAGE:-tdai-memory-knowledge:intranet}
panel_image=${PANEL_IMAGE:-tdai-memory-panel:intranet}
proxy_image=${PROXY_IMAGE:-tdai-memory-proxy:intranet}
image_names="$core_image $knowledge_image $panel_image $proxy_image"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tdai-memory-offline.XXXXXX")
media_dir="$work_dir/$media_name"
archive="$out_dir/$media_name.tar.gz"
archive_checksum="$archive.sha256"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

require_file() {
  test -f "$1" || {
    echo "required file is missing: $1" >&2
    exit 1
  }
}

require_image() {
  image=$1
  docker image inspect "$image" >/dev/null 2>&1 || {
    echo "required image is not available locally: $image" >&2
    exit 1
  }
  image_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
  if [ "$image_platform" != "$target_platform" ]; then
    echo "image platform mismatch: $image is $image_platform, expected $target_platform" >&2
    exit 1
  fi
}

sha256_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
  else
    shasum -a 256 "$file"
  fi
}

copy_file() {
  source=$1
  destination=$2
  require_file "$source"
  mkdir -p "$(dirname -- "$destination")"
  cp "$source" "$destination"
}

for image in $image_names; do
  require_image "$image"
done
if [ "$include_debian_image" = 1 ]; then
  require_image "$debian_image"
  image_names="$image_names $debian_image"
fi

mkdir -p "$media_dir/images" "$media_dir/deploy/intranet/config" "$media_dir/deploy/intranet/scripts" "$media_dir/docs"

copy_file "$repo_root/deploy/intranet/docker-compose.yml" "$media_dir/deploy/intranet/docker-compose.yml"
copy_file "$repo_root/deploy/intranet/.env.example" "$media_dir/deploy/intranet/.env.example"
copy_file "$repo_root/deploy/intranet/README_CN.md" "$media_dir/deploy/intranet/README_CN.md"
copy_file "$repo_root/deploy/intranet/config/metadata-instances.template.json" "$media_dir/deploy/intranet/config/metadata-instances.template.json"
copy_file "$repo_root/deploy/intranet/config/proxy.yaml" "$media_dir/deploy/intranet/config/proxy.yaml"
copy_file "$repo_root/deploy/intranet/config/tdai-gateway.yaml" "$media_dir/deploy/intranet/config/tdai-gateway.yaml"
copy_file "$repo_root/deploy/intranet/scripts/bootstrap-admin.sh" "$media_dir/deploy/intranet/scripts/bootstrap-admin.sh"
copy_file "$repo_root/deploy/intranet/scripts/verify.sh" "$media_dir/deploy/intranet/scripts/verify.sh"
copy_file "$repo_root/deploy/intranet/scripts/verify-debian10-uos-runtime.sh" "$media_dir/deploy/intranet/scripts/verify-debian10-uos-runtime.sh"
copy_file "$repo_root/deploy/intranet/scripts/verify-offline-media.sh" "$media_dir/deploy/intranet/scripts/verify-offline-media.sh"
copy_file "$repo_root/docs/DEPLOYMENT_CN.md" "$media_dir/docs/DEPLOYMENT_CN.md"
copy_file "$repo_root/docs/USAGE_CN.md" "$media_dir/docs/USAGE_CN.md"
copy_file "$repo_root/INSTALL_CN.md" "$media_dir/INSTALL_CN.md"

docker save $image_names -o "$media_dir/images/tdai-memory-intranet-images.tar"
gzip -c "$media_dir/images/tdai-memory-intranet-images.tar" > "$media_dir/images/tdai-memory-intranet-images.tar.gz"
rm -f "$media_dir/images/tdai-memory-intranet-images.tar"

{
  printf '{\n'
  printf '  "format": "tdai-memory-intranet-offline-v1",\n'
  printf '  "sourceCommit": "%s",\n' "$source_commit"
  printf '  "sourceBranch": "%s",\n' "$source_branch"
  printf '  "targetPlatform": "%s",\n' "$target_platform"
  printf '  "runtimeNetworkRequired": false,\n'
  printf '  "images": [\n'
  first=1
  for image in $image_names; do
    image_id=$(docker image inspect --format '{{.Id}}' "$image")
    image_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    printf '    {"name":"%s","id":"%s","platform":"%s"}' "$image" "$image_id" "$image_platform"
    first=0
  done
  printf '\n  ],\n'
  printf '  "imageArchive": "images/tdai-memory-intranet-images.tar.gz",\n'
  printf '  "verification": "deploy/intranet/scripts/verify-offline-media.sh"\n'
  printf '}\n'
} > "$media_dir/MANIFEST.json"

cat > "$media_dir/README_OFFLINE_CN.md" <<'EOF'
# TencentDB Agent Memory 内网离线介质

本目录包含四个已构建的 Docker 镜像、无密钥 Compose 配置、部署/使用手册和校验文件。

1. 先执行 `sha256sum -c SHA256SUMS`。
2. 再执行 `./deploy/intranet/scripts/verify-offline-media.sh .`。
3. 首次部署前复制 `deploy/intranet/.env.example` 为 `.env`，只填写内网地址和密钥。
4. 导入镜像：`gunzip -c images/tdai-memory-intranet-images.tar.gz | docker load`。
5. 使用 `docker compose --env-file .env -f deploy/intranet/docker-compose.yml up -d --no-build` 启动。

该介质不包含真实 `.env`、API key 或业务数据。运行期不需要 npm/apt 下载；内网 LLM 仍是业务运行所需的独立服务。
EOF

(cd "$media_dir" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r file; do sha256_file "$file"; done) > "$media_dir/SHA256SUMS"

rm -f "$archive" "$archive_checksum"
tar -C "$work_dir" -czf "$archive" "$media_name"
(cd "$out_dir" && sha256_file "$(basename "$archive")") > "$archive_checksum"

echo "offline media: $archive"
echo "outer checksum: $archive_checksum"
echo "source commit: $source_commit"
echo "target platform: $target_platform"
