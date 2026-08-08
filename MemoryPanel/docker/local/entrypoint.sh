#!/bin/sh
set -eu

template="${METADATA_INSTANCES_TEMPLATE:-}"
output="${METADATA_INSTANCES_CONFIG:-/tmp/metadata-instances.json}"

if [ -n "$template" ]; then
  node --input-type=module - "$template" "$output" <<'NODE'
import { readFileSync, writeFileSync, chmodSync } from "node:fs";
import { dirname } from "node:path";
import { mkdirSync } from "node:fs";

const [, , templatePath, outputPath] = process.argv;
const source = readFileSync(templatePath, "utf8");
const missing = new Set();
const rendered = source.replace(/\$\{([A-Z_][A-Z0-9_]*)\}/g, (_match, name) => {
  const value = process.env[name];
  if (!value) missing.add(name);
  return value ?? "";
});

if (missing.size > 0) {
  throw new Error(`missing required metadata template variables: ${[...missing].join(", ")}`);
}

JSON.parse(rendered);
mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, rendered, { encoding: "utf8", mode: 0o600 });
chmodSync(outputPath, 0o600);
NODE
  export METADATA_INSTANCES_CONFIG="$output"
fi

case "${1:-start}" in
  start)
    shift || true
    exec node --import tsx/esm src/index.ts "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
