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
    "llvm_mingw": "${LLVM_MINGW_TAG}",
    "zlib": "${ZLIB_VERSION:-}",
    "libxml2": "${LIBXML2_DEB_VERSION:-}"
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
      tar --no-same-owner -xzf "$archive" -C "$tmp"
      local prefix
      prefix="$(find "$tmp" -maxdepth 1 -type d -name 'cmake-*' | head -1)"
      [[ -n "$prefix" ]] || { echo "cmake prefix missing in $archive" >&2; exit 1; }
      cp -a "${prefix}/bin/cmake" "${stage}/bin/cmake"
      # Keep cmake modules next to bin (../share relative to bin/cmake).
      mkdir -p "${stage}/share"
      if compgen -G "${prefix}/share/cmake-*" >/dev/null; then
        cp -a "${prefix}/share/cmake-"* "${stage}/share/"
      else
        cp -a "${prefix}/share/." "${stage}/share/"
      fi
      ;;
    windows)
      need unzip
      unzip -q "$archive" -d "$tmp"
      local prefix
      prefix="$(find "$tmp" -maxdepth 1 -type d -name 'cmake-*' | head -1)"
      [[ -n "$prefix" ]] || { echo "cmake prefix missing in $archive" >&2; exit 1; }
      cp -a "${prefix}/bin/cmake.exe" "${stage}/bin/cmake.exe"
      mkdir -p "${stage}/share"
      cp -a "${prefix}/share/." "${stage}/share/"
      # cmake.exe often needs adjacent DLLs from bin/
      find "${prefix}/bin" -maxdepth 1 -name '*.dll' -exec cp -a {} "${stage}/bin/" \;
      ;;
    macos)
      # Kitware archives ship Apple UIDs; ignore ownership on Linux CI.
      tar --no-same-owner -xzf "$archive" -C "$tmp" || \
        tar --no-same-owner -xzf "$archive" -C "$tmp" --warning=no-unknown-keyword || true
      # Official layout: cmake-*-macos-universal/CMake.app/Contents/...
      local cmake_bin
      cmake_bin="$(find "$tmp" -type f -path '*/bin/cmake' | head -1)"
      [[ -n "$cmake_bin" && -x "$cmake_bin" ]] || {
        echo "cmake binary missing in $archive" >&2
        exit 1
      }
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

# Cross-build static zlib into a Windows llvm-mingw stage (run on Linux).
# Installs headers + libz.a under stage/{include,lib} and the x86_64 sysroot.
stage_zlib_mingw_windows() {
  local stage="$1"
  local zlib_ver="${ZLIB_VERSION:?ZLIB_VERSION unset}"
  local linux_asset="${LLVM_MINGW_LINUX_ASSET:?LLVM_MINGW_LINUX_ASSET unset}"
  local zlib_url="https://github.com/madler/zlib/releases/download/v${zlib_ver}/zlib-${zlib_ver}.tar.gz"
  local zlib_arc="${CACHE}/zlib-${zlib_ver}.tar.gz"
  local mingw_url="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_TAG}/${linux_asset}"
  local mingw_arc="${CACHE}/${linux_asset}"

  need make
  need tar
  download "$zlib_url" "$zlib_arc"
  download "$mingw_url" "$mingw_arc"

  local xtmp ztmp
  xtmp="$(mktemp -d)"
  ztmp="$(mktemp -d)"

  echo "extracting linux-hosted llvm-mingw (zlib cross-build)…"
  tar --no-same-owner -xJf "$mingw_arc" -C "$xtmp"
  local xroot
  xroot="$(find "$xtmp" -maxdepth 1 -type d -name 'llvm-mingw-*' | head -1)"
  if [[ -z "$xroot" || ! -x "${xroot}/bin/x86_64-w64-mingw32-clang" ]]; then
    rm -rf "$xtmp" "$ztmp"
    echo "linux llvm-mingw layout unexpected" >&2
    exit 1
  fi

  tar --no-same-owner -xzf "$zlib_arc" -C "$ztmp"
  local zsrc
  zsrc="$(find "$ztmp" -maxdepth 1 -type d -name 'zlib-*' | head -1)"
  if [[ -z "$zsrc" || ! -f "${zsrc}/zlib.h" ]]; then
    rm -rf "$xtmp" "$ztmp"
    echo "zlib source missing in $zlib_arc" >&2
    exit 1
  fi

  echo "cross-building zlib ${zlib_ver} (static)…"
  # win32/Makefile.gcc: set absolute tool paths (PREFIX unused when CC is full).
  make -C "$zsrc" -f win32/Makefile.gcc clean >/dev/null 2>&1 || true
  if ! make -C "$zsrc" -f win32/Makefile.gcc -j"$(nproc 2>/dev/null || echo 4)" \
    CC="${xroot}/bin/x86_64-w64-mingw32-clang" \
    AR="${xroot}/bin/llvm-ar" \
    RANLIB="${xroot}/bin/llvm-ranlib" \
    STRIP="${xroot}/bin/llvm-strip" \
    RC="${xroot}/bin/llvm-windres" \
    libz.a; then
    rm -rf "$xtmp" "$ztmp"
    echo "zlib cross-build failed" >&2
    exit 1
  fi

  if [[ ! -f "${zsrc}/libz.a" ]]; then
    rm -rf "$xtmp" "$ztmp"
    echo "zlib cross-build failed (libz.a missing)" >&2
    exit 1
  fi

  mkdir -p "${stage}/include" "${stage}/lib" \
    "${stage}/x86_64-w64-mingw32/include" "${stage}/x86_64-w64-mingw32/lib"
  cp -a "${zsrc}/zlib.h" "${zsrc}/zconf.h" "${stage}/include/"
  cp -a "${zsrc}/zlib.h" "${zsrc}/zconf.h" "${stage}/x86_64-w64-mingw32/include/"
  cp -a "${zsrc}/libz.a" "${stage}/lib/libz.a"
  cp -a "${zsrc}/libz.a" "${stage}/x86_64-w64-mingw32/lib/libz.a"
  rm -rf "$xtmp" "$ztmp"
  echo "staged zlib ${zlib_ver} -> include/ + lib/libz.a (+ x86_64 sysroot)"
}

# Copy self-install / uninstall helpers into the pack stage (zip root).
# $1 = stage root, $2 = family: unix | windows
stage_bundle_scripts() {
  local stage="$1" family="$2"
  local src="${ROOT}/scripts/bundle/${family}"
  [[ -d "$src" ]] || { echo "bundle scripts missing: $src" >&2; exit 1; }
  case "$family" in
    unix)
      cp -a "${src}/install.sh" "${src}/uninstall.sh" "${stage}/"
      chmod +x "${stage}/install.sh" "${stage}/uninstall.sh"
      ;;
    windows)
      cp -a "${src}/install.ps1" "${src}/uninstall.ps1" \
        "${src}/install.bat" "${src}/uninstall.bat" "${stage}/"
      ;;
    *)
      echo "unknown bundle family: $family (want unix|windows)" >&2
      exit 1
      ;;
  esac
  echo "staged ${family} install/uninstall scripts → ${stage}/"
}

make_zip() {
  local stage="$1" zip_path="$2"
  need zip
  mkdir -p "$(dirname "$zip_path")"
  rm -f "$zip_path"
  local abs_zip
  abs_zip="$(cd "$(dirname "$zip_path")" && pwd)/$(basename "$zip_path")"
  ( cd "$stage" && zip -qr "$abs_zip" . )
  echo "Wrote $abs_zip ($(du -h "$abs_zip" | awk '{print $1}'))"
}
