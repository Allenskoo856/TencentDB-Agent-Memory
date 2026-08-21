#!/bin/sh
set -eu

smoke=0
media_dir=.
for arg in "$@"; do
  case "$arg" in
    --docker-smoke) smoke=1 ;;
    --help|-h)
      echo "Usage: $0 [MEDIA_DIR] [--docker-smoke]"
      exit 0
      ;;
    *) media_dir=$arg ;;
  esac
done

media_dir=$(CDPATH= cd -- "$media_dir" && pwd)
checksum_file="$media_dir/SHA256SUMS"
image_archive="$media_dir/images/tdai-memory-intranet-images.tar.gz"

test -f "$checksum_file" || { echo "missing $checksum_file" >&2; exit 1; }
test -f "$image_archive" || { echo "missing $image_archive" >&2; exit 1; }
test -f "$media_dir/MANIFEST.json" || { echo "missing MANIFEST.json" >&2; exit 1; }
test -f "$media_dir/deploy/intranet/docker-compose.yml" || { echo "missing Compose file" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$media_dir" && sha256sum --strict -c SHA256SUMS)
else
  (
    cd "$media_dir"
    while IFS='  ' read -r expected file; do
      actual=$(shasum -a 256 "$file" | awk '{print $1}')
      test "$actual" = "$expected" || {
        echo "$file: FAILED" >&2
        exit 1
      }
      echo "$file: OK"
    done < SHA256SUMS
  )
fi
echo "offline media checksums passed: $media_dir"

if [ "$smoke" = 1 ]; then
  command -v docker >/dev/null 2>&1 || { echo "docker is required for --docker-smoke" >&2; exit 2; }
  gunzip -c "$image_archive" | docker load
  (
    cd "$media_dir"
    PULL_DEBIAN_IMAGE=0 ./deploy/intranet/scripts/verify-debian10-uos-runtime.sh
  )
  echo "offline media Docker smoke passed"
fi
