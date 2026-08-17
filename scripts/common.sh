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
    "ccache": "${CCACHE_VERSION:-}",
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
    # Windows PBS: urllib → _socket.pyd under DLLs/ (launcher generate + toolchain_pack).
    [[ -f "${dest}/DLLs/_socket.pyd" ]] || {
      echo "missing DLLs/_socket.pyd under ${dest}" >&2
      exit 1
    }
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

# Stage official ccache prebuilt into stage/bin/.
# $1 = archive path, $2 = stage root, $3 = dest name: ccache | ccache.exe
# $4 = archive kind: tar.xz | tar.gz | zip
stage_ccache() {
  local archive="$1" stage="$2" exe_name="$3" kind="$4"
  local tmp
  tmp="$(mktemp -d)"
  case "$kind" in
    tar.xz)
      need tar
      tar --no-same-owner -xJf "$archive" -C "$tmp"
      ;;
    tar.gz)
      need tar
      tar --no-same-owner -xzf "$archive" -C "$tmp"
      ;;
    zip)
      need unzip
      unzip -q "$archive" -d "$tmp"
      ;;
    *)
      rm -rf "$tmp"
      echo "stage_ccache: unknown kind $kind" >&2
      exit 1
      ;;
  esac
  local ccache_bin
  ccache_bin="$(find "$tmp" -type f \( -name ccache -o -name ccache.exe \) | head -1)"
  [[ -n "$ccache_bin" ]] || {
    rm -rf "$tmp"
    echo "ccache missing in $archive" >&2
    exit 1
  }
  mkdir -p "${stage}/bin"
  cp -a "$ccache_bin" "${stage}/bin/${exe_name}"
  chmod +x "${stage}/bin/${exe_name}" 2>/dev/null || true
  rm -rf "$tmp"
  echo "staged ccache → ${stage}/bin/${exe_name}"
}

# Cross-build static zlib into a Windows llvm-mingw stage (run on Linux).
# Installs under stage/deps/ (NOT stage/include — that mingw tree poisons libc++
# when used as ZLIB_ROOT / CMAKE_PREFIX_PATH). Also mirrors into the sysroot.
stage_zlib_mingw_windows() {
  local stage="$1"
  local deps="${stage}/deps"
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

  mkdir -p "${deps}/include" "${deps}/lib" \
    "${stage}/x86_64-w64-mingw32/include" "${stage}/x86_64-w64-mingw32/lib"
  cp -a "${zsrc}/zlib.h" "${zsrc}/zconf.h" "${deps}/include/"
  cp -a "${zsrc}/libz.a" "${deps}/lib/libz.a"
  # Sysroot only (compiler -isystem); never stage/include next to mingw math.h.
  cp -a "${zsrc}/zlib.h" "${zsrc}/zconf.h" "${stage}/x86_64-w64-mingw32/include/"
  cp -a "${zsrc}/libz.a" "${stage}/x86_64-w64-mingw32/lib/libz.a"
  rm -rf "$xtmp" "$ztmp"
  echo "staged zlib ${zlib_ver} -> deps/{include,lib} (+ x86_64 sysroot)"
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
# Installs under stage/deps/ so find_package(SDL3) does not -isystem the mingw
# top-level include/ (breaks libc++ <cmath>/<cwchar> on Windows packs).
stage_sdl3_mingw_windows() {
  local stage_in="$1"
  local stage
  stage="$(cd "$stage_in" && pwd)"
  local deps="${stage}/deps"
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
  mkdir -p "$sbuild" "$deps"
  echo "cross-building SDL3 ${sdl_ver} (static, llvm-mingw → deps/)…"
  if ! cmake -S "$ssrc" -B "$sbuild" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="${xroot}/bin/x86_64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="${xroot}/bin/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="${xroot}/bin/llvm-windres" \
    -DCMAKE_AR="${xroot}/bin/llvm-ar" \
    -DCMAKE_RANLIB="${xroot}/bin/llvm-ranlib" \
    -DCMAKE_INSTALL_PREFIX="${deps}" \
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

  # Optional sysroot mirror for bare -isystem sysroot searches.
  mkdir -p "${stage}/x86_64-w64-mingw32/include" "${stage}/x86_64-w64-mingw32/lib/cmake"
  if [[ -d "${deps}/include/SDL3" ]]; then
    cp -a "${deps}/include/SDL3" "${stage}/x86_64-w64-mingw32/include/"
  fi
  if [[ -f "${deps}/lib/libSDL3.a" ]]; then
    cp -a "${deps}/lib/libSDL3.a" "${stage}/x86_64-w64-mingw32/lib/"
  fi
  if [[ -d "${deps}/lib/cmake/SDL3" ]]; then
    cp -a "${deps}/lib/cmake/SDL3" "${stage}/x86_64-w64-mingw32/lib/cmake/"
  fi

  rm -rf "$xtmp" "$stmp"
  if [[ ! -f "${deps}/lib/cmake/SDL3/SDL3Config.cmake" && \
        ! -f "${deps}/lib/cmake/SDL3/SDL3-config.cmake" ]]; then
    echo "SDL3 CMake package missing after install" >&2
    exit 1
  fi
  if [[ ! -f "${deps}/lib/libSDL3.a" ]]; then
    echo "SDL3 static library missing after install" >&2
    exit 1
  fi
  echo "staged SDL3 ${sdl_ver} -> deps/{include/SDL3,lib/libSDL3.a,lib/cmake/SDL3}"
}

# Extract an Ubuntu .deb's data.tar into stage/sysroot/ (merge usr/ + lib/).
# Used to assemble a jammy build sysroot for SteamOS / headerless hosts.
stage_deb_into_sysroot() {
  local deb="$1" stage="$2"
  [[ -f "$deb" ]] || { echo "deb missing: $deb" >&2; exit 1; }
  local tmp
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
  mkdir -p "${stage}/sysroot"
  # Preserve multiarch layout (usr/include, usr/lib/x86_64-linux-gnu, lib/…).
  if [[ -d "${tmp}/usr" ]]; then
    mkdir -p "${stage}/sysroot/usr"
    cp -a "${tmp}/usr/." "${stage}/sysroot/usr/"
  fi
  if [[ -d "${tmp}/lib" ]]; then
    mkdir -p "${stage}/sysroot/lib"
    cp -a "${tmp}/lib/." "${stage}/sysroot/lib/"
  fi
  rm -rf "$tmp"
  echo "sysroot ← $(basename "$deb")"
}

# Ubuntu jammy amd64 build sysroot: glibc + linux uapi + libstdc++ + OpenGL.
# Also stages zlib headers/static lib into deps/ for ZLIB_ROOT (like Windows).
stage_linux_sysroot() {
  local stage="$1"
  local -a urls=(
    "${SYSROOT_LIBC6_URL:?}"
    "${SYSROOT_LIBC6_DEV_URL:?}"
    "${SYSROOT_LINUX_LIBC_DEV_URL:?}"
    "${SYSROOT_LIBGCC_S1_URL:?}"
    "${SYSROOT_LIBSTDCPP6_URL:?}"
    "${SYSROOT_LIBSTDCPP_DEV_URL:?}"
    "${SYSROOT_LIBGLVND0_URL:?}"
    "${SYSROOT_LIBGL1_URL:?}"
    "${SYSROOT_LIBGLX0_URL:?}"
    "${SYSROOT_LIBGLVND_DEV_URL:?}"
    "${SYSROOT_LIBGL_DEV_URL:?}"
    "${SYSROOT_ZLIB1G_URL:?}"
    "${SYSROOT_ZLIB1G_DEV_URL:?}"
  )
  local url arc
  echo "assembling Linux build sysroot (Ubuntu jammy amd64)…"
  for url in "${urls[@]}"; do
    arc="${CACHE}/$(basename "$url")"
    download "$url" "$arc"
    stage_deb_into_sysroot "$arc" "$stage"
  done

  # Sanity: headers + CRT objects the clang driver needs under --sysroot.
  local sr="${stage}/sysroot"
  [[ -f "${sr}/usr/include/unistd.h" || -f "${sr}/usr/include/x86_64-linux-gnu/unistd.h" ]] || {
    echo "sysroot missing unistd.h" >&2
    exit 1
  }
  # Ubuntu multiarch: sys/types.h lives under usr/include/<triplet>/sys/
  # (clang --sysroot adds that dir to the include path).
  [[ -f "${sr}/usr/include/sys/types.h" \
    || -f "${sr}/usr/include/x86_64-linux-gnu/sys/types.h" ]] || {
    echo "sysroot missing sys/types.h" >&2
    exit 1
  }
  [[ -f "${sr}/usr/include/GL/gl.h" ]] || {
    echo "sysroot missing GL/gl.h" >&2
    exit 1
  }
  # libstdc++ multiarch include root (versioned).
  local cxxinc
  cxxinc="$(find "${sr}/usr/include/c++" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
  [[ -n "$cxxinc" && -f "${cxxinc}/cstdio" ]] || {
    echo "sysroot missing libstdc++ headers under usr/include/c++" >&2
    exit 1
  }
  local crt
  crt="$(find "${sr}/usr/lib" -name 'Scrt1.o' | head -1 || true)"
  [[ -n "$crt" ]] || {
    echo "sysroot missing Scrt1.o (libc6-dev)" >&2
    exit 1
  }

  # Ubuntu libc.so linker script references /lib64/ld-linux-x86-64.so.2; the
  # libc6 deb only installs the loader under lib/x86_64-linux-gnu/.
  mkdir -p "${sr}/lib64"
  if [[ -e "${sr}/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" ]]; then
    ln -sfn ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
      "${sr}/lib64/ld-linux-x86-64.so.2"
  else
    echo "sysroot missing ld-linux-x86-64.so.2 (libc6)" >&2
    exit 1
  fi

  # libgcc-s1 ships libgcc_s.so.1 only; --unwindlib=libgcc needs -lgcc_s.
  if [[ -e "${sr}/lib/x86_64-linux-gnu/libgcc_s.so.1" ]]; then
    ln -sfn libgcc_s.so.1 "${sr}/lib/x86_64-linux-gnu/libgcc_s.so"
  else
    echo "sysroot missing libgcc_s.so.1 (libgcc-s1)" >&2
    exit 1
  fi

  # Mirror zlib into deps/ so find_package(ZLIB) / ZLIB_ROOT works without
  # FetchContent (matches Windows pack layout).
  mkdir -p "${stage}/deps/include" "${stage}/deps/lib"
  if [[ -f "${sr}/usr/include/zlib.h" ]]; then
    cp -a "${sr}/usr/include/zlib.h" "${stage}/deps/include/"
    # zconf.h is multiarch on Ubuntu (usr/include/<triplet>/zconf.h).
    if [[ -f "${sr}/usr/include/zconf.h" ]]; then
      cp -a "${sr}/usr/include/zconf.h" "${stage}/deps/include/"
    else
      local zconf
      zconf="$(find "${sr}/usr/include" -name 'zconf.h' | head -1 || true)"
      if [[ -n "$zconf" ]]; then
        cp -a "$zconf" "${stage}/deps/include/zconf.h"
      fi
    fi
  fi
  local zlib_a
  zlib_a="$(find "${sr}/usr/lib" -name 'libz.a' | head -1 || true)"
  if [[ -n "$zlib_a" ]]; then
    cp -a "$zlib_a" "${stage}/deps/lib/libz.a"
  fi
  [[ -f "${stage}/deps/include/zlib.h" && -f "${stage}/deps/lib/libz.a" ]] || {
    echo "failed to stage zlib into deps/ from sysroot debs" >&2
    exit 1
  }

  # Drop bulky non-link/compile bits from -dev packages (keep lean).
  rm -rf "${sr}/usr/share/doc" "${sr}/usr/share/man" "${sr}/usr/share/lintian" \
    "${sr}/usr/share/gcc" "${sr}/usr/lib/gcc"/*/*-linux-gnu/*/include-fixed \
    2>/dev/null || true
  # Keep gcc/*/crt*.o if any slipped in under lib/gcc — usually Scrt1 is enough
  # with compiler-rt, but libstdc++.so linker scripts may reference gcc paths.
  echo "staged Linux sysroot → ${sr} (+ zlib → deps/)"
}

# Rewrite clang.cfg after sysroot is present. <CFGDIR> is the directory that
# contains the config file (clang's bin/), so ../sysroot is pack-relative.
write_linux_clang_cfg() {
  local stage="$1"
  local with_sysroot="${2:-0}"
  {
    printf '%s\n' '-fuse-ld=lld'
    printf '%s\n' '--rtlib=compiler-rt'
    if [[ "$with_sysroot" == "1" ]]; then
      # Relative to bin/; absolute via Clang <CFGDIR> expansion.
      printf '%s\n' '--sysroot=<CFGDIR>/../sysroot'
      # Prefer the jammy multiarch triple inside the sysroot.
      printf '%s\n' '--target=x86_64-unknown-linux-gnu'
      # Without a host GCC install, clang will not auto-discover libstdc++.
      # Point at the versioned jammy paths staged under sysroot/.
      local cxx_ver gcc_lib
      cxx_ver="$(basename "$(find "${stage}/sysroot/usr/include/c++" -mindepth 1 -maxdepth 1 -type d | head -1)")"
      gcc_lib="$(find "${stage}/sysroot/usr/lib/gcc/x86_64-linux-gnu" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
      if [[ -z "$cxx_ver" || ! -f "${stage}/sysroot/usr/include/c++/${cxx_ver}/string" ]]; then
        echo "write_linux_clang_cfg: libstdc++ headers missing under sysroot" >&2
        exit 1
      fi
      if [[ -z "$gcc_lib" || ! -e "${gcc_lib}/libstdc++.so" ]]; then
        echo "write_linux_clang_cfg: libstdc++.so missing under sysroot usr/lib/gcc" >&2
        exit 1
      fi
      printf '%s\n' "--unwindlib=libgcc"
      printf '%s\n' "-isystem<CFGDIR>/../sysroot/usr/include/c++/${cxx_ver}"
      printf '%s\n' "-isystem<CFGDIR>/../sysroot/usr/include/x86_64-linux-gnu/c++/${cxx_ver}"
      printf '%s\n' "-L<CFGDIR>/../sysroot/usr/lib/gcc/x86_64-linux-gnu/$(basename "$gcc_lib")"
    fi
  } >"${stage}/bin/clang.cfg"
  cp -a "${stage}/bin/clang.cfg" "${stage}/bin/clang++.cfg"
}

# Native-build static SDL3 into a Linux clang stage (needs host X11/ALSA headers).
#
# MUST run with clang.cfg that does NOT yet force --sysroot, on a host whose
# glibc matches the jammy build sysroot (2.35). Packaging CI uses ubuntu-22.04
# for that reason: building SDL3 on ubuntu-24.04 embeds __isoc23_* / strlcpy
# refs that jammy (and SteamOS link sysroot) cannot resolve.
stage_sdl3_linux() {
  local stage_in="$1"
  local stage
  stage="$(cd "$stage_in" && pwd)"
  local sdl_ver="${SDL3_VERSION:?SDL3_VERSION unset}"
  local sdl_url="${SDL3_URL:?SDL3_URL unset}"
  local sdl_arc="${CACHE}/${SDL3_TARBALL:?SDL3_TARBALL unset}"
  local cc="${stage}/bin/clang"
  local cxx="${stage}/bin/clang++"
  local ar="${stage}/bin/llvm-ar"
  local ranlib="${stage}/bin/llvm-ranlib"

  need cmake
  need ninja
  need tar
  [[ -x "$cc" ]] || {
    echo "stage_sdl3_linux: stage clang missing ($cc)" >&2
    exit 1
  }

  # Guard: host glibc must be ≤ jammy (2.35). Newer hosts produce an SDL3.a
  # that fails to link against pack sysroot/libc (Debian/SteamOS symptom:
  # undefined __isoc23_strtol / strlcpy / wcslcpy).
  local host_glibc=""
  if host_glibc="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | tail -1)"; then
    local major minor
    major="${host_glibc%%.*}"
    minor="${host_glibc#*.}"
    minor="${minor%%.*}"
    if [[ "$major" -gt 2 || ( "$major" -eq 2 && "$minor" -gt 35 ) ]]; then
      echo "stage_sdl3_linux: host glibc ${host_glibc} is newer than jammy 2.35." >&2
      echo "  Build the Linux pack on ubuntu-22.04 (or equal) so deps/libSDL3.a" >&2
      echo "  matches the bundled jammy sysroot (SteamOS / Debian / Deck)." >&2
      exit 1
    fi
  fi

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
  echo "building SDL3 ${sdl_ver} (static, pack clang, jammy-compatible glibc)…"
  # Absolute compiler paths required — CMake rejects relative CMAKE_C_COMPILER
  # when the tool is not already on PATH (CI pack stages are relative).
  if ! cmake -S "$ssrc" -B "$sbuild" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_CXX_COMPILER="$cxx" \
    -DCMAKE_AR="$ar" \
    -DCMAKE_RANLIB="$ranlib" \
    -DCMAKE_INSTALL_PREFIX="${stage}/deps" \
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
  if [[ ! -f "${stage}/deps/lib/libSDL3.a" ]]; then
    echo "SDL3 static library missing after install" >&2
    exit 1
  fi
  echo "staged SDL3 ${sdl_ver} -> deps/{include/SDL3,lib/libSDL3.a,lib/cmake/SDL3}"
}

# Fail the pack if libSDL3.a still references glibc symbols the jammy sysroot
# cannot provide (noble/24.04 build leak).
assert_sdl3_jammy_linkable() {
  local stage="$1"
  local lib="${stage}/deps/lib/libSDL3.a"
  local nm_bin="${stage}/bin/llvm-nm"
  [[ -f "$lib" ]] || {
    echo "assert_sdl3_jammy_linkable: missing $lib" >&2
    exit 1
  }
  [[ -x "$nm_bin" ]] || nm_bin="nm"
  local undef
  undef="$("$nm_bin" -u "$lib" 2>/dev/null | awk '{print $NF}' | sort -u || true)"
  local bad=""
  local sym
  for sym in __isoc23_strtol __isoc23_strtoul __isoc23_strtoll __isoc23_strtoull \
    __isoc23_sscanf __isoc23_vsscanf __isoc23_fscanf __isoc23_wcstol \
    strlcpy strlcat wcslcpy wcslcat; do
    if printf '%s\n' "$undef" | grep -qx "$sym"; then
      bad+=" $sym"
    fi
  done
  if [[ -n "$bad" ]]; then
    echo "libSDL3.a has undefined symbols the jammy sysroot lacks:${bad}" >&2
    echo "  Rebuild the Linux pack on ubuntu-22.04 (glibc 2.35)." >&2
    exit 1
  fi
  echo "libSDL3.a jammy-link smoke OK (no __isoc23_* / strlcpy / wcslcpy undefs)"
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
