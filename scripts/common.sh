#!/usr/bin/env bash
# Shared helpers for assembling cmake-clang-v1 packs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/pins.env"

PACK_VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
CACHE="${RETCOMM_TC_CACHE:-${ROOT}/.cache/downloads}"
OUT_DEFAULT="${ROOT}/dist"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }

download() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    echo "cache hit: $dest"
    return 0
  fi
  echo "download: $url"
  curl -fL --retry 3 --retry-delay 2 -o "${dest}.partial" "$url"
  mv "${dest}.partial" "$dest"
}

write_meta() {
  local stage="$1" os_tag="$2" kind="$3"
  cat >"${stage}/retcomm-toolchain.json" <<EOF
{
  "id": "${PACK_ID}",
  "version": "${PACK_VERSION}",
  "os": "${os_tag}",
  "kind": "${kind}",
  "pins": {
    "cmake": "${CMAKE_VERSION}",
    "ninja": "${NINJA_VERSION}",
    "llvm": "${LLVM_VERSION}",
    "llvm_mingw": "${LLVM_MINGW_TAG}"
  }
}
EOF
}

stage_cmake_from_archive() {
  # $1 = archive path, $2 = stage root, $3 = platform: linux|windows|macos
  local archive="$1" stage="$2" platform="$3"
  local tmp
  tmp="$(mktemp -d)"
  case "$platform" in
    linux)
      tar -xzf "$archive" -C "$tmp"
      local prefix
      prefix="$(find "$tmp" -maxdepth 1 -type d -name 'cmake-*' | head -1)"
      cp -a "${prefix}/bin/cmake" "${stage}/bin/cmake"
      # Keep cmake's private libs/modules next to bin via relative layout.
      mkdir -p "${stage}/share"
      cp -a "${prefix}/share/cmake-"* "${stage}/share/" 2>/dev/null || \
        cp -a "${prefix}/share/." "${stage}/share/"
      if [[ -d "${prefix}/bin" ]]; then
        # cpack/ctest optional — skip to save space
        true
      fi
      ;;
    windows)
      need unzip
      unzip -q "$archive" -d "$tmp"
      local prefix
      prefix="$(find "$tmp" -maxdepth 1 -type d -name 'cmake-*' | head -1)"
      cp -a "${prefix}/bin/cmake.exe" "${stage}/bin/cmake.exe"
      mkdir -p "${stage}/share"
      cp -a "${prefix}/share/." "${stage}/share/"
      # cmake.exe often needs adjacent DLLs from bin/
      find "${prefix}/bin" -maxdepth 1 -name '*.dll' -exec cp -a {} "${stage}/bin/" \;
      ;;
    macos)
      tar -xzf "$archive" -C "$tmp"
      # Official layout: cmake-*-macos-universal/CMake.app/Contents/...
      local cmake_bin
      cmake_bin="$(find "$tmp" -type f -path '*/bin/cmake' | head -1)"
      [[ -n "$cmake_bin" ]] || { echo "cmake binary missing in $archive" >&2; exit 1; }
      local contents
      contents="$(cd "$(dirname "$cmake_bin")/.." && pwd)"
      cp -a "${contents}/bin/cmake" "${stage}/bin/cmake"
      mkdir -p "${stage}/share"
      if [[ -d "${contents}/share" ]]; then
        cp -a "${contents}/share/." "${stage}/share/"
      fi
      ;;
    *)
      echo "unknown cmake platform: $platform" >&2
      exit 1
      ;;
  esac
  rm -rf "$tmp"
}

stage_ninja() {
  local archive="$1" stage="$2" exe_name="$3"
  local tmp
  tmp="$(mktemp -d)"
  need unzip
  unzip -q "$archive" -d "$tmp"
  local ninja_bin
  ninja_bin="$(find "$tmp" -type f \( -name ninja -o -name ninja.exe \) | head -1)"
  [[ -n "$ninja_bin" ]] || { echo "ninja missing in $archive" >&2; exit 1; }
  cp -a "$ninja_bin" "${stage}/bin/${exe_name}"
  chmod +x "${stage}/bin/${exe_name}" 2>/dev/null || true
  rm -rf "$tmp"
}

make_zip() {
  local stage="$1" zip_path="$2"
  need zip
  rm -f "$zip_path"
  mkdir -p "$(dirname "$zip_path")"
  ( cd "$stage" && zip -qr "$zip_path" . )
  echo "Wrote $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
}
