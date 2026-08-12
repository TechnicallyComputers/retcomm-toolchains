#!/usr/bin/env bash
# Assemble cmake-clang-v1-linux-x64.zip (portable clang/lld + cmake + ninja).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need curl
need tar
need zip
need file
need ar

OUT="${1:-$OUT_DEFAULT}"
OS_TAG="linux-x64"
STAGE="${OUT}/stage-${PACK_ID}-${OS_TAG}"
ZIP="${OUT}/${PACK_ID}-${OS_TAG}.zip"

CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"
NINJA_URL="https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-linux.zip"
CCACHE_ASSET="ccache-${CCACHE_VERSION}-linux-x86_64-musl-static.tar.xz"
CCACHE_URL="https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/${CCACHE_ASSET}"
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/${LLVM_TAG}/${LLVM_LINUX_ASSET}"

CMAKE_ARC="${CACHE}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"
NINJA_ARC="${CACHE}/ninja-${NINJA_VERSION}-linux.zip"
CCACHE_ARC="${CACHE}/${CCACHE_ASSET}"
LLVM_ARC="${CACHE}/${LLVM_LINUX_ASSET}"
LIBXML2_ARC="${CACHE}/${LIBXML2_DEB_ASSET}"
LIBICU70_ARC="${CACHE}/${LIBICU70_DEB_ASSET}"

download "$CMAKE_URL" "$CMAKE_ARC"
download "$NINJA_URL" "$NINJA_ARC"
download "$CCACHE_URL" "$CCACHE_ARC"
download "$LLVM_URL" "$LLVM_ARC"
download "${LIBXML2_DEB_URL}" "$LIBXML2_ARC"
download "${LIBICU70_DEB_URL}" "$LIBICU70_ARC"

rm -rf "$STAGE"
mkdir -p "${STAGE}/bin" "${STAGE}/lib" "${OUT}"

# --- LLVM (pruned) ---
LLVM_TMP="$(mktemp -d)"
echo "extracting LLVM (lean subset)…"
# First pass: discover the versioned clang-N binary name from the archive index.
CLANG_REAL="$(tar -tf "$LLVM_ARC" | grep -E '/bin/clang-[0-9]+$' | head -1 || true)"
CLANG_REAL="${CLANG_REAL##*/}"
[[ -n "$CLANG_REAL" ]] || CLANG_REAL="clang-22"

tar --no-same-owner -xJf "$LLVM_ARC" -C "$LLVM_TMP" \
  --wildcards \
  "*/bin/clang" \
  "*/bin/clang++" \
  "*/bin/${CLANG_REAL}" \
  "*/bin/clang-cpp" \
  "*/bin/lld" \
  "*/bin/ld.lld" \
  "*/bin/llvm-ar" \
  "*/bin/llvm-ranlib" \
  "*/bin/llvm-nm" \
  "*/bin/llvm-objcopy" \
  "*/bin/llvm-strip" \
  "*/lib/clang" \
  || true

LLVM_ROOT="$(find "$LLVM_TMP" -maxdepth 1 -type d -name 'LLVM-*' | head -1)"
[[ -n "$LLVM_ROOT" && -e "${LLVM_ROOT}/bin/clang" ]] || {
  echo "failed to extract clang from $LLVM_ARC" >&2
  exit 1
}

# Drop sanitizer / coverage runtimes (keep builtins + includes).
find "${LLVM_ROOT}/lib/clang" -type f \( \
  -name '*asan*' -o -name '*tsan*' -o -name '*hwasan*' -o -name '*ubsan*' \
  -o -name '*fuzzer*' -o -name '*xray*' -o -name '*memprof*' -o -name '*rtsan*' \
  -o -name '*nsan*' -o -name '*dfsan*' -o -name '*safestack*' -o -name '*gwp*' \
  -o -name '*profile*' -o -name '*cfi*' -o -name '*scudo*' -o -name '*msan*' \
  \) -delete 2>/dev/null || true
find "${LLVM_ROOT}/lib/clang" -type d -empty -delete 2>/dev/null || true

# Keep only the compiler driver bits we need in bin/.
keep_bins=(clang clang++ clang-cpp lld ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip)
# Preserve versioned clang-N real binary if clang is a symlink.
if [[ -L "${LLVM_ROOT}/bin/clang" ]]; then
  keep_bins+=("$(readlink "${LLVM_ROOT}/bin/clang")")
fi

cp -a "${LLVM_ROOT}/lib/clang" "${STAGE}/lib/"
for b in "${keep_bins[@]}"; do
  [[ -e "${LLVM_ROOT}/bin/${b}" ]] || continue
  cp -a "${LLVM_ROOT}/bin/${b}" "${STAGE}/bin/"
done
# Convenience aliases
ln -sf clang "${STAGE}/bin/cc"
ln -sf clang++ "${STAGE}/bin/c++"
chmod +x "${STAGE}/bin/"* 2>/dev/null || true
rm -rf "$LLVM_TMP"

# --- libxml2.so.2 + ICU 70 (lld deps; Fedora/Cachy often lack these SONAMEs) ---
echo "extracting libxml2 ${LIBXML2_DEB_VERSION}…"
stage_deb_shared_libs "$LIBXML2_ARC" "$STAGE" 'libxml2.so.2' 'libxml2.so.2.*'
echo "extracting libicu70 ${LIBICU70_DEB_VERSION}…"
# libxml2→icuuc→icudata; skip i18n/io/test/tu to keep the pack lean.
stage_deb_shared_libs "$LIBICU70_ARC" "$STAGE" \
  'libicuuc.so.70' 'libicuuc.so.70.*' \
  'libicudata.so.70' 'libicudata.so.70.*'

# Prefer pack lib/ without requiring callers to set LD_LIBRARY_PATH.
# lld → libxml2 (via RUNPATH on the binary); libxml2 → libicuuc (via RUNPATH
# on the *shared object* — the executable's RUNPATH does not apply to NEEDED
# of libraries it loads when DT_RUNPATH is used).
if command -v patchelf >/dev/null 2>&1; then
  for b in lld ld.lld; do
    [[ -f "${STAGE}/bin/${b}" ]] || continue
    patchelf --set-rpath '$ORIGIN/../lib' "${STAGE}/bin/${b}"
  done
  for so in "${STAGE}/lib"/libxml2.so.* "${STAGE}/lib"/libicuuc.so.*; do
    [[ -e "$so" && ! -L "$so" ]] || continue
    patchelf --set-rpath '$ORIGIN' "$so"
  done
else
  echo "warning: patchelf not found; relying on LD_LIBRARY_PATH for bundled libs" >&2
fi

# Default to lld so Release IPO (-flto=thin) does not require LLVMgold.so + system ld.
printf '%s\n' '-fuse-ld=lld' >"${STAGE}/bin/clang.cfg"
printf '%s\n' '-fuse-ld=lld' >"${STAGE}/bin/clang++.cfg"

stage_cmake_from_archive "$CMAKE_ARC" "$STAGE" linux
stage_ninja "$NINJA_ARC" "$STAGE" ninja
stage_ccache "$CCACHE_ARC" "$STAGE" ccache tar.xz
stage_sdl3_linux "$STAGE"
stage_python_standalone "$STAGE" "x86_64-unknown-linux-gnu"

cat >"${STAGE}/env.sh" <<'EOF'
#!/usr/bin/env bash
# Source:  . ./env.sh
PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case ":${PATH}:" in
  *":${PACK_ROOT}/bin:"*) ;;
  *) export PATH="${PACK_ROOT}/bin${PATH:+:${PATH}}" ;;
esac
case ":${PATH}:" in
  *":${PACK_ROOT}/python/bin:"*) ;;
  *) export PATH="${PACK_ROOT}/python/bin${PATH:+:${PATH}}" ;;
esac
export CC="${PACK_ROOT}/bin/clang"
export CXX="${PACK_ROOT}/bin/clang++"
export AR="${PACK_ROOT}/bin/llvm-ar"
export RANLIB="${PACK_ROOT}/bin/llvm-ranlib"
# Bundled libxml2.so.2 + libicuuc/libicudata .70 for lld; clang.cfg → -fuse-ld=lld.
case ":${LD_LIBRARY_PATH:-}:" in
  *":${PACK_ROOT}/lib:"*) ;;
  *) export LD_LIBRARY_PATH="${PACK_ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
esac
case " ${LDFLAGS:-} " in
  *" -fuse-ld=lld "*|*" -fuse-ld=lld") ;;
  *) export LDFLAGS="-fuse-ld=lld${LDFLAGS:+ ${LDFLAGS}}" ;;
esac
export RETCOMM_TOOLCHAIN_DIR="${PACK_ROOT}"
export RETCOMM_PYTHON="${PACK_ROOT}/python/bin/python3"
if [[ -f "${PACK_ROOT}/deps/lib/cmake/SDL3/SDL3Config.cmake" ||
      -f "${PACK_ROOT}/deps/lib/cmake/SDL3/SDL3-config.cmake" ]]; then
  export SDL3_DIR="${PACK_ROOT}/deps/lib/cmake/SDL3"
fi
EOF
chmod +x "${STAGE}/env.sh"

cat >"${STAGE}/README.md" <<EOF
# ${PACK_ID} (${OS_TAG})

Portable RetComM / psxrecomp toolchain pack:

- LLVM/Clang ${LLVM_VERSION} + lld (pruned official Linux-X64 build)
- Bundled \`libxml2.so.2\` + \`libicuuc.so.70\` / \`libicudata.so.70\` (Ubuntu jammy)
  so lld runs on hosts that only ship newer SONAMEs (e.g. ICU 78)
- \`clang.cfg\` / \`clang++.cfg\` default to \`-fuse-ld=lld\` (Release LTO / IPO without LLVMgold)
- CMake ${CMAKE_VERSION}
- Ninja ${NINJA_VERSION}
- ccache ${CCACHE_VERSION} (compiler cache; speeds cold/rebuild after path moves)
- SDL3 ${SDL3_VERSION} under \`deps/\` (static \`libSDL3.a\` + CMake CONFIG)
- CPython ${PYTHON_VERSION} (python-build-standalone; no system Python required)

## Install (recommended)

From this extracted zip root — copies into the shared RetComM cache and adds
\`latest/bin\` to your shell PATH (idempotent):

\`\`\`bash
./install.sh
cmake --version
clang --version
\`\`\`

Remove later (idempotent PATH cleanup):

\`\`\`bash
./uninstall.sh
\`\`\`

## Session-only (no PATH change)

\`\`\`bash
. ./env.sh
cmake --version
clang --version
\`\`\`

RetComM / title wizards also find the pack under
\`~/.local/share/retcomm/toolchains/${PACK_ID}/\` after \`./install.sh\`.

Uses the host glibc / libstdc++ (typical for Linux portable clang). Requires a
reasonably modern x86_64 glibc (Ubuntu 22.04+ / similar).

Pack version: ${PACK_VERSION}
EOF

write_meta "$STAGE" "$OS_TAG" "llvm-clang-lld"
stage_bundle_scripts "$STAGE" unix

# Smoke (including thin LTO — the MotK Release IPO path)
[[ -x "${STAGE}/install.sh" ]]
[[ -x "${STAGE}/uninstall.sh" ]]
[[ -x "${STAGE}/python/bin/python3" ]]
[[ -f "${STAGE}/deps/lib/libSDL3.a" ]]
[[ -f "${STAGE}/deps/lib/cmake/SDL3/SDL3Config.cmake" ]] || \
  [[ -f "${STAGE}/deps/lib/cmake/SDL3/SDL3-config.cmake" ]]
[[ -d "${STAGE}/deps/include/SDL3" ]]
export PATH="${STAGE}/bin:${PATH}"
# Prove RUNPATH/$ORIGIN without ambient LD_LIBRARY_PATH (wizard often only
# prepends bin/ to PATH; env.sh still sets LD_LIBRARY_PATH as a belt).
unset LD_LIBRARY_PATH || true
"${STAGE}/bin/cmake" --version | head -1
"${STAGE}/bin/clang" --version | head -1
"${STAGE}/bin/ninja" --version
"${STAGE}/bin/ccache" --version | head -1
"${STAGE}/bin/ld.lld" --version | head -1
"${STAGE}/python/bin/python3" -c 'import sys; print(sys.version)'
[[ -x "${STAGE}/bin/ccache" ]]
# libicuuc is a NEEDED of bundled libxml2 — must resolve via libxml2's $ORIGIN.
XML_ICU="$(ldd "${STAGE}/lib/libxml2.so.2" \
  | awk '/libicuuc\.so\.70/{print $3; exit}')"
STAGE_LIB_ABS="$(cd "${STAGE}/lib" && pwd)"
[[ -n "$XML_ICU" && -e "$XML_ICU" ]] || {
  echo "libxml2.so.2 unresolved libicuuc.so.70 (ldd)" >&2
  ldd "${STAGE}/lib/libxml2.so.2" >&2 || true
  exit 1
}
XML_ICU_ABS="$(cd "$(dirname "$XML_ICU")" && pwd)/$(basename "$XML_ICU")"
case "$XML_ICU_ABS" in
  "${STAGE_LIB_ABS}/"*) ;;
  *)
    echo "libxml2 libicuuc.so.70 not from pack lib/ (got: $XML_ICU_ABS)" >&2
    exit 1
    ;;
esac
echo "libxml2 → libicuuc.so.70 → ${XML_ICU_ABS}"
echo 'int main(){return 0;}' >"${STAGE}/.smoke.c"
"${STAGE}/bin/clang" "${STAGE}/.smoke.c" -o "${STAGE}/.smoke"
"${STAGE}/.smoke"
"${STAGE}/bin/clang" "${STAGE}/.smoke.c" -flto=thin -O2 -o "${STAGE}/.smoke_lto"
"${STAGE}/.smoke_lto"
rm -f "${STAGE}/.smoke" "${STAGE}/.smoke_lto" "${STAGE}/.smoke.c"

make_zip "$STAGE" "$ZIP"
