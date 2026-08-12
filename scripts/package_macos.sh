#!/usr/bin/env bash
# Assemble cmake-clang-v1-macos-*.zip (cmake + ninja; system Apple clang / Xcode CLT).
# $1 = os tag: macos-arm64 | macos-x64 | macos-universal
# $2 = optional out dir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need curl
need tar
need unzip
need zip

OS_TAG="${1:-macos-universal}"
OUT="${2:-$OUT_DEFAULT}"
STAGE="${OUT}/stage-${PACK_ID}-${OS_TAG}"
ZIP="${OUT}/${PACK_ID}-${OS_TAG}.zip"

CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
NINJA_URL="https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-mac.zip"
CCACHE_ASSET="ccache-${CCACHE_VERSION}-darwin.tar.gz"
CCACHE_URL="https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/${CCACHE_ASSET}"

CMAKE_ARC="${CACHE}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
NINJA_ARC="${CACHE}/ninja-${NINJA_VERSION}-mac.zip"
CCACHE_ARC="${CACHE}/${CCACHE_ASSET}"

download "$CMAKE_URL" "$CMAKE_ARC"
download "$NINJA_URL" "$NINJA_ARC"
download "$CCACHE_URL" "$CCACHE_ARC"

rm -rf "$STAGE"
mkdir -p "${STAGE}/bin" "${OUT}"

stage_cmake_from_archive "$CMAKE_ARC" "$STAGE" macos
stage_ninja "$NINJA_ARC" "$STAGE" ninja
stage_ccache "$CCACHE_ARC" "$STAGE" ccache tar.gz
stage_python_macos_universal "$STAGE"

cat >"${STAGE}/env.sh" <<'EOF'
#!/usr/bin/env bash
PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case ":${PATH}:" in
  *":${PACK_ROOT}/bin:"*) ;;
  *) export PATH="${PACK_ROOT}/bin${PATH:+:${PATH}}" ;;
esac
case ":${PATH}:" in
  *":${PACK_ROOT}/python/bin:"*) ;;
  *) export PATH="${PACK_ROOT}/python/bin${PATH:+:${PATH}}" ;;
esac
# Prefer Xcode CLT / Xcode clang — required for Apple SDK headers & link.
if [[ -x /usr/bin/clang ]]; then
  export CC="${CC:-/usr/bin/clang}"
  export CXX="${CXX:-/usr/bin/clang++}"
fi
export RETCOMM_TOOLCHAIN_DIR="${PACK_ROOT}"
export RETCOMM_PYTHON="${PACK_ROOT}/python/bin/python3"
EOF
chmod +x "${STAGE}/env.sh"

cat >"${STAGE}/README.md" <<EOF
# ${PACK_ID} (${OS_TAG})

macOS RetComM toolchain helpers:

- CMake ${CMAKE_VERSION} (universal)
- Ninja ${NINJA_VERSION}
- ccache ${CCACHE_VERSION} (universal Darwin binary)
- CPython ${PYTHON_VERSION} (python-build-standalone, arm64 + x86_64)

**Apple Clang + Xcode Command Line Tools are required** (system SDK). This pack
does not bundle a compiler — same approach as GitHub \`macos-*\` runners.

## Install CLT (if needed)

\`\`\`bash
xcode-select -p >/dev/null 2>&1 || xcode-select --install
clang --version
\`\`\`

## Install (recommended)

From this extracted zip root — shared RetComM cache + shell PATH (idempotent):

\`\`\`bash
./install.sh
cmake --version
ninja --version
\`\`\`

\`\`\`bash
./uninstall.sh
\`\`\`

## Session-only (no PATH change)

\`\`\`bash
. ./env.sh
cmake --version
ninja --version
\`\`\`

Pack version: ${PACK_VERSION}
EOF

write_meta "$STAGE" "$OS_TAG" "cmake-ninja-system-clang"
stage_bundle_scripts "$STAGE" unix

[[ -x "${STAGE}/bin/cmake" ]]
[[ -x "${STAGE}/bin/ninja" ]]
[[ -x "${STAGE}/bin/ccache" ]]
[[ -x "${STAGE}/python/bin/python3" ]]
[[ -x "${STAGE}/python/aarch64-apple-darwin/bin/python3" ]]
[[ -x "${STAGE}/python/x86_64-apple-darwin/bin/python3" ]]
[[ -x "${STAGE}/install.sh" ]]
[[ -x "${STAGE}/uninstall.sh" ]]

make_zip "$STAGE" "$ZIP"
