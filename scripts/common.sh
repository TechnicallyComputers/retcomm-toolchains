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
    "sdl3": "${SDL3_VERSION:-}",
    "libxml2": "${LIBXML2_DEB_VERSION:-}",
    "libicu70": "${LIBICU70_DEB_VERSION:-}",
    "python": "${PYTHON_VERSION:-}",
    "python_pbs": "${PYTHON_PBS_TAG:-}"
  }
}
EOF
}

# Stage astral-sh python-build-standalone install_only_stripped under stage/python/
# (or stage/python/<subdir>/ for multi-arch macos).
# $1 = stage root
# $2 = PBS target triple (e.g. x86_64-unknown-linux-gnu)
# $3 = optional subdir under python/ (empty → stage/python)
stage_python_standalone() {
  local stage="$1" triple="$2" subdir="${3:-}"
  local py_ver="${PYTHON_VERSION:?PYTHON_VERSION unset}"
  local pbs_tag="${PYTHON_PBS_TAG:?PYTHON_PBS_TAG unset}"
  local prefix="${PYTHON_PBS_URL_PREFIX:?PYTHON_PBS_URL_PREFIX unset}"
  local asset="cpython-${py_ver}+${pbs_tag}-${triple}-install_only_stripped.tar.gz"
  local url="${prefix}/${asset}"
  local arc="${CACHE}/${asset}"

  need tar
  download "$url" "$arc"

  local tmp dest
  tmp="$(mktemp -d)"
  echo "extracting CPython ${py_ver} (${triple})…"
  tar --no-same-owner -xzf "$arc" -C "$tmp"

  # install_only layout: top-level python/ with bin/python3 or python.exe
  local py_root
  py_root="$(find "$tmp" -maxdepth 2 -type d -name python | head -1)"
  [[ -n "$py_root" ]] || {
    rm -rf "$tmp"
    echo "python/ missing in $asset" >&2
    exit 1
  }

  if [[ -n "$subdir" ]]; then
    dest="${stage}/python/${subdir}"
  else
    dest="${stage}/python"
  fi
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$py_root" "$dest"
  rm -rf "$tmp"

  if [[ -f "${dest}/python.exe" ]]; then
    echo "staged CPython ${py_ver} → ${dest}/python.exe"
  elif [[ -x "${dest}/bin/python3" || -x "${dest}/bin/python" ]]; then
    chmod +x "${dest}/bin/python3" "${dest}/bin/python" 2>/dev/null || true
    echo "staged CPython ${py_ver} → ${dest}/bin/python3"
  else
    echo "python binary missing under ${dest}" >&2
    exit 1
  fi
}

# macOS universal: both Darwin arches + a small dispatcher as python/bin/python3.
stage_python_macos_universal() {
  local stage="$1"
  stage_python_standalone "$stage" "aarch64-apple-darwin" "aarch64-apple-darwin"
  stage_python_standalone "$stage" "x86_64-apple-darwin" "x86_64-apple-darwin"
  mkdir -p "${stage}/python/bin"
  cat >"${stage}/python/bin/python3" <<'EOF'
#!/bin/sh
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$ARCH" in
  arm64|aarch64) EXEC="${ROOT}/aarch64-apple-darwin/bin/python3" ;;
  x86_64|i386|i686) EXEC="${ROOT}/x86_64-apple-darwin/bin/python3" ;;
  *)
    echo "retcomm python: unsupported macOS arch: $ARCH" >&2
    exit 127
    ;;
esac
exec "$EXEC" "$@"
EOF
  chmod +x "${stage}/python/bin/python3"
  ln -sf python3 "${stage}/python/bin/python"
}

# Extract matching shared libraries from an Ubuntu .deb into stage/lib/.
# $1 = .deb path, $2 = stage root, remaining args = find -name patterns (OR).
stage_deb_shared_libs() {
  local deb="$1" stage="$2"
  shift 2
  [[ $# -ge 1 ]] || { echo "stage_deb_shared_libs: need at least one -name pattern" >&2; exit 1; }
  [[ -f "$deb" ]] || { echo "deb missing: $deb" >&2; exit 1; }
  local tmp find_args=()
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    ar x "$deb"
    if [[ -f data.tar.xz ]]; then
      tar --no-same-owner -xJf data.tar.xz
    elif [[ -f data.tar.zst ]]; then
      tar --no-same-owner --zstd -xf data.tar.zst
    elif [[ -f data.tar.gz ]]; then
      tar --no-same-owner -xzf data.tar.gz
    else
      echo "deb missing data.tar.* in $deb" >&2
      exit 1
    fi
  )
  # (file OR symlink) AND (name1 OR name2 …) — SONAME links are often symlinks.
  find_args=(\( -type f -o -type l \) \()
  local first=1 pat
  for pat in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      find_args+=(-name "$pat")
      first=0
    else
      find_args+=(-o -name "$pat")
    fi
  done
  find_args+=(\))
  local -a sos=()
  mapfile -t sos < <(find "$tmp" "${find_args[@]}" | sort -u)
  if [[ "${#sos[@]}" -eq 0 ]]; then
    rm -rf "$tmp"
    echo "no matching .so in $deb (patterns: $*)" >&2
    exit 1
  fi
  mkdir -p "${stage}/lib"
  local so
  for so in "${sos[@]}"; do
    cp -a "$so" "${stage}/lib/"
  done
  # Real ELF objects need +x so the loader / ldd treat them as shared libs.
  find "${stage}/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' \
    -exec chmod a+x {} + 2>/dev/null || true
  rm -rf "$tmp"
  echo "staged ${#sos[@]} shared lib(s) from $(basename "$deb") → ${stage}/lib/"
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

# Verify a downloaded SDL3 tarball matches the pin (optional if sha256sum missing).
_verify_sdl3_sha256() {
  local arc="$1"
  local expect="${SDL3_SHA256:?SDL3_SHA256 unset}"
  if command -v sha256sum >/dev/null 2>&1; then
    local got
    got="$(sha256sum "$arc" | awk '{print $1}')"
    if [[ "$got" != "$expect" ]]; then
      echo "SDL3 tarball hash mismatch: $got (want $expect)" >&2
      rm -f "$arc"
      exit 1
    fi
  fi
}

# Cross-build static SDL3 into a Windows llvm-mingw stage (run on Linux).
# Installs headers + libSDL3.a + CMake CONFIG under stage/ for find_package(SDL3).
stage_sdl3_mingw_windows() {
  local stage="$1"
  local sdl_ver="${SDL3_VERSION:?SDL3_VERSION unset}"
  local linux_asset="${LLVM_MINGW_LINUX_ASSET:?LLVM_MINGW_LINUX_ASSET unset}"
  local sdl_url="${SDL3_URL:?SDL3_URL unset}"
  local sdl_arc="${CACHE}/${SDL3_TARBALL:?SDL3_TARBALL unset}"
  local mingw_url="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_TAG}/${linux_asset}"
  local mingw_arc="${CACHE}/${linux_asset}"

  need cmake
  need ninja
  need tar
  download "$sdl_url" "$sdl_arc"
  _verify_sdl3_sha256 "$sdl_arc"
  download "$mingw_url" "$mingw_arc"

  local xtmp stmp
  xtmp="$(mktemp -d)"
  stmp="$(mktemp -d)"

  echo "extracting linux-hosted llvm-mingw (SDL3 cross-build)…"
  tar --no-same-owner -xJf "$mingw_arc" -C "$xtmp"
  local xroot
  xroot="$(find "$xtmp" -maxdepth 1 -type d -name 'llvm-mingw-*' | head -1)"
  if [[ -z "$xroot" || ! -x "${xroot}/bin/x86_64-w64-mingw32-clang" ]]; then
    rm -rf "$xtmp" "$stmp"
    echo "linux llvm-mingw layout unexpected" >&2
    exit 1
  fi

  tar --no-same-owner -xzf "$sdl_arc" -C "$stmp"
  local ssrc
  ssrc="$(find "$stmp" -maxdepth 1 -type d -name 'SDL3-*' | head -1)"
  if [[ -z "$ssrc" || ! -f "${ssrc}/CMakeLists.txt" ]]; then
    rm -rf "$xtmp" "$stmp"
    echo "SDL3 source missing in $sdl_arc" >&2
    exit 1
  fi

  local sbuild="${stmp}/build-mingw"
  mkdir -p "$sbuild"
  echo "cross-building SDL3 ${sdl_ver} (static, llvm-mingw)…"
  if ! cmake -S "$ssrc" -B "$sbuild" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="${xroot}/bin/x86_64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="${xroot}/bin/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="${xroot}/bin/llvm-windres" \
    -DCMAKE_AR="${xroot}/bin/llvm-ar" \
    -DCMAKE_RANLIB="${xroot}/bin/llvm-ranlib" \
    -DCMAKE_INSTALL_PREFIX="${stage}" \
    -DSDL_SHARED=OFF \
    -DSDL_STATIC=ON \
    -DSDL_TEST_LIBRARY=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_DOCS=OFF; then
    rm -rf "$xtmp" "$stmp"
    echo "SDL3 cmake configure failed" >&2
    exit 1
  fi
  if ! cmake --build "$sbuild" -j"$(nproc 2>/dev/null || echo 4)"; then
    rm -rf "$xtmp" "$stmp"
    echo "SDL3 build failed" >&2
    exit 1
  fi
  if ! cmake --install "$sbuild"; then
    rm -rf "$xtmp" "$stmp"
    echo "SDL3 install failed" >&2
    exit 1
  fi

  # Mirror into the mingw sysroot so bare sysroot searches also work.
  mkdir -p "${stage}/x86_64-w64-mingw32/include" "${stage}/x86_64-w64-mingw32/lib/cmake"
  if [[ -d "${stage}/include/SDL3" ]]; then
    cp -a "${stage}/include/SDL3" "${stage}/x86_64-w64-mingw32/include/"
  fi
  if [[ -f "${stage}/lib/libSDL3.a" ]]; then
    cp -a "${stage}/lib/libSDL3.a" "${stage}/x86_64-w64-mingw32/lib/"
  fi
  if [[ -d "${stage}/lib/cmake/SDL3" ]]; then
    cp -a "${stage}/lib/cmake/SDL3" "${stage}/x86_64-w64-mingw32/lib/cmake/"
  fi

  rm -rf "$xtmp" "$stmp"
  if [[ ! -f "${stage}/lib/cmake/SDL3/SDL3Config.cmake" && \
        ! -f "${stage}/lib/cmake/SDL3/SDL3-config.cmake" ]]; then
    echo "SDL3 CMake package missing after install" >&2
    exit 1
  fi
  if [[ ! -f "${stage}/lib/libSDL3.a" ]]; then
    echo "SDL3 static library missing after install" >&2
    exit 1
  fi
  echo "staged SDL3 ${sdl_ver} -> include/SDL3 + lib/libSDL3.a + lib/cmake/SDL3"
}

# Native-build static SDL3 into a Linux clang stage (needs host X11/ALSA headers).
stage_sdl3_linux() {
  local stage="$1"
  local sdl_ver="${SDL3_VERSION:?SDL3_VERSION unset}"
  local sdl_url="${SDL3_URL:?SDL3_URL unset}"
  local sdl_arc="${CACHE}/${SDL3_TARBALL:?SDL3_TARBALL unset}"

  need cmake
  need ninja
  need tar
  [[ -x "${stage}/bin/clang" ]] || {
    echo "stage_sdl3_linux: stage clang missing" >&2
    exit 1
  }
  download "$sdl_url" "$sdl_arc"
  _verify_sdl3_sha256 "$sdl_arc"

  local stmp
  stmp="$(mktemp -d)"
  tar --no-same-owner -xzf "$sdl_arc" -C "$stmp"
  local ssrc
  ssrc="$(find "$stmp" -maxdepth 1 -type d -name 'SDL3-*' | head -1)"
  if [[ -z "$ssrc" || ! -f "${ssrc}/CMakeLists.txt" ]]; then
    rm -rf "$stmp"
    echo "SDL3 source missing in $sdl_arc" >&2
    exit 1
  fi

  local sbuild="${stmp}/build-linux"
  mkdir -p "$sbuild"
  echo "building SDL3 ${sdl_ver} (static, pack clang)…"
  if ! cmake -S "$ssrc" -B "$sbuild" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${stage}/bin/clang" \
    -DCMAKE_CXX_COMPILER="${stage}/bin/clang++" \
    -DCMAKE_AR="${stage}/bin/llvm-ar" \
    -DCMAKE_RANLIB="${stage}/bin/llvm-ranlib" \
    -DCMAKE_INSTALL_PREFIX="${stage}" \
    -DSDL_SHARED=OFF \
    -DSDL_STATIC=ON \
    -DSDL_TEST_LIBRARY=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_DOCS=OFF; then
    rm -rf "$stmp"
    echo "SDL3 cmake configure failed (install X11/ALSA/Pulse devel packages?)" >&2
    exit 1
  fi
  if ! cmake --build "$sbuild" -j"$(nproc 2>/dev/null || echo 4)"; then
    rm -rf "$stmp"
    echo "SDL3 build failed" >&2
    exit 1
  fi
  if ! cmake --install "$sbuild"; then
    rm -rf "$stmp"
    echo "SDL3 install failed" >&2
    exit 1
  fi
  rm -rf "$stmp"
  if [[ ! -f "${stage}/lib/libSDL3.a" ]]; then
    echo "SDL3 static library missing after install" >&2
    exit 1
  fi
  echo "staged SDL3 ${sdl_ver} -> include/SDL3 + lib/libSDL3.a + lib/cmake/SDL3"
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
