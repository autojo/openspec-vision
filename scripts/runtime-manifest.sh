#!/usr/bin/env bash
# runtime-manifest.sh -- record or verify the exact runtime that is vendored in
# runtime/bin.
#
#   ./scripts/runtime-manifest.sh --write   (re)write runtime/MANIFEST.sha256
#   ./scripts/runtime-manifest.sh           verify the runtime against it
#
# Why: the runtime is a snapshot of another repository (see runtime/VENDOR.md).
# Without a manifest, "is the installed copy the snapshot we think it is?" can
# only be answered by reading the files. The manifest makes the snapshot
# checkable by CI and by 'boss --version'.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/runtime/bin"
MANIFEST="$ROOT/runtime/MANIFEST.sha256"
mode="${1:-verify}"

# sha256_file <file> -- portable SHA-256, one of the usual four tools.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -- "$1" | sed 's/^.*= //'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  else
    printf 'error: no SHA-256 tool available\n' >&2
    exit 2
  fi
}

# entries -- "hash  runtime/bin/<name>" for every runtime file, stable order.
entries() {
  local file name
  for file in "$BIN"/boss "$BIN"/boss-lib.sh "$BIN"/boss-waiter "$BIN"/boss-*.sh; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    printf '%s  runtime/bin/%s\n' "$(sha256_file "$file")" "$name"
  done | sort -k2 -u
}

case "$mode" in
  --write|-w)
    mkdir -p "$(dirname "$MANIFEST")"
    {
      printf '# SHA-256 of the vendored runtime, sorted by file name.\n'
      printf '# Regenerate with scripts/runtime-manifest.sh --write after an\n'
      printf '# intentional change to runtime/bin; CI verifies it.\n'
      entries
    } >"$MANIFEST"
    printf 'wrote %s\n' "${MANIFEST#"$ROOT"/}"
    ;;
  verify|--verify|-v)
    [ -f "$MANIFEST" ] || { printf 'error: missing %s\n' "${MANIFEST#"$ROOT"/}" >&2; exit 1; }
    want="$(grep -v '^#' "$MANIFEST" | grep -v '^$')"
    have="$(entries)"
    if [ "$want" = "$have" ]; then
      printf 'runtime matches the manifest (%s files)\n' "$(printf '%s\n' "$have" | wc -l | tr -d ' ')"
      exit 0
    fi
    printf 'runtime differs from runtime/MANIFEST.sha256:\n' >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") >&2 || true
    printf 'If the change was intentional, run scripts/runtime-manifest.sh --write\n' >&2
    exit 1
    ;;
  *)
    printf 'usage: %s [--write|--verify]\n' "$0" >&2
    exit 2
    ;;
esac
