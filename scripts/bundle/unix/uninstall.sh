#!/usr/bin/env bash
# Remove this toolchain from the shared RetComM cache and from the user PATH.
#
# Run from the extracted zip root or from the installed cache copy:
#   ./uninstall.sh
#   ./uninstall.sh --all-versions
set -euo pipefail

PACK_ID="${RETCOMM_PACK_ID:-cmake-clang-v1}"
MARKER_BEGIN="# >>> retcomm-toolchain (${PACK_ID}) >>>"
MARKER_END="# <<< retcomm-toolchain (${PACK_ID}) <<<"
ALL_VERSIONS=0

usage() {
  cat <<EOF
Usage: ./uninstall.sh [--all-versions] [--help]

Remove ${PACK_ID} from the shared RetComM cache and strip its PATH hook
from your shell profiles (idempotent if already removed).

Options:
  --all-versions   Delete every <tag>/ under the pack cache (default: this version + latest)
  --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all-versions) ALL_VERSIONS=1; shift ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

retcomm_data_home() {
  if [[ -n "${RETCOMM_DATA_HOME:-}" ]]; then
    printf '%s\n' "${RETCOMM_DATA_HOME}"
  elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
    printf '%s\n' "${XDG_DATA_HOME}/retcomm"
  else
    printf '%s\n' "${HOME}/.local/share/retcomm"
  fi
}

cache_root() {
  if [[ -n "${RETCOMM_TOOLCHAIN_CACHE:-}" ]]; then
    printf '%s\n' "${RETCOMM_TOOLCHAIN_CACHE}"
  else
    printf '%s\n' "$(retcomm_data_home)/toolchains/${PACK_ID}"
  fi
}

read_version_from() {
  local root="$1"
  local meta="${root}/retcomm-toolchain.json"
  [[ -f "$meta" ]] || { echo ""; return; }
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("version","").strip())' "$meta" 2>/dev/null && return
  fi
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" | head -1
}

sanitize_tag() {
  local s="$1"
  s="${s//[^A-Za-z0-9._-]/_}"
  printf '%s\n' "${s:-}"
}

strip_profile_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$file" >"$tmp"
  # If unchanged, leave mtime alone
  if cmp -s "$file" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$file"
  echo "Removed PATH hook from ${file}"
}

# Drop BIN_DIR occurrences from the current session PATH.
strip_session_path() {
  local drop="$1"
  local IFS=':'
  local -a keep=()
  local p
  for p in ${PATH:-}; do
    [[ -z "$p" ]] && continue
    [[ "$p" == "$drop" ]] && continue
    keep+=("$p")
  done
  if [[ ${#keep[@]} -eq 0 ]]; then
    export PATH=""
  else
    local out="${keep[0]}"
    local i
    for ((i = 1; i < ${#keep[@]}; i++)); do
      out+=":${keep[i]}"
    done
    export PATH="$out"
  fi
}

CACHE="$(cache_root)"
LATEST="${CACHE}/latest"
HOOK="${CACHE}/path.sh"
BIN_DIR="${LATEST}/bin"

VER="$(read_version_from "$SCRIPT_ROOT")"
TAG="$(sanitize_tag "$VER")"

# Prefer removing the cache tag that matches this pack's version; if the
# script lives inside the cache already, SCRIPT_ROOT may be DEST.
DEST=""
if [[ -n "$TAG" && -d "${CACHE}/${TAG}" ]]; then
  DEST="${CACHE}/${TAG}"
elif [[ "$SCRIPT_ROOT" == "$CACHE"/* && "$SCRIPT_ROOT" != "$CACHE" ]]; then
  DEST="$SCRIPT_ROOT"
fi

echo "Uninstalling ${PACK_ID}${VER:+ ${VER}} from ${CACHE}"

for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
  strip_profile_block "$rc"
done

rm -f "$HOOK"

if [[ "$ALL_VERSIONS" == "1" ]]; then
  if [[ -d "$CACHE" ]]; then
    rm -rf "$CACHE"
    echo "Removed cache tree ${CACHE}"
  fi
else
  if [[ -e "$LATEST" || -L "$LATEST" ]]; then
    rm -rf "$LATEST"
    echo "Removed ${LATEST}"
  fi
  if [[ -n "$DEST" && -d "$DEST" ]]; then
    rm -rf "$DEST"
    echo "Removed ${DEST}"
  fi
  # Drop empty cache parent
  if [[ -d "$CACHE" ]]; then
    rmdir "$CACHE" 2>/dev/null || true
  fi
fi

strip_session_path "$BIN_DIR"
# Also strip the versioned bin if different from latest
if [[ -n "$DEST" ]]; then
  strip_session_path "${DEST}/bin"
fi

if [[ "${RETCOMM_TOOLCHAIN_DIR:-}" == "$LATEST" || "${RETCOMM_TOOLCHAIN_DIR:-}" == "$DEST" ]]; then
  unset RETCOMM_TOOLCHAIN_DIR
fi

cat <<EOF

${PACK_ID} PATH hooks removed (idempotent if already clean).
Open a new terminal for a fully clean environment, or continue in this shell
(PATH already stripped for this session).
EOF
