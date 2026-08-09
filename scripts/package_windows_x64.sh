#!/usr/bin/env bash
# Assemble cmake-clang-v1-windows-x64.zip (llvm-mingw UCRT + cmake + ninja).
# Can run on Linux (download + zip) — does not execute Windows binaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need curl
need unzip
need zip

OUT="${1:-$OUT_DEFAULT}"
OS_TAG="windows-x64"
STAGE="${OUT}/stage-${PACK_ID}-${OS_TAG}"
ZIP="${OUT}/${PACK_ID}-${OS_TAG}.zip"

CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-windows-x86_64.zip"
NINJA_URL="https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-win.zip"
MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_TAG}/${LLVM_MINGW_ASSET}"

CMAKE_ARC="${CACHE}/cmake-${CMAKE_VERSION}-windows-x86_64.zip"
NINJA_ARC="${CACHE}/ninja-${NINJA_VERSION}-win.zip"
MINGW_ARC="${CACHE}/${LLVM_MINGW_ASSET}"

download "$CMAKE_URL" "$CMAKE_ARC"
download "$NINJA_URL" "$NINJA_ARC"
download "$MINGW_URL" "$MINGW_ARC"

rm -rf "$STAGE"
mkdir -p "${STAGE}/bin" "${OUT}"

MINGW_TMP="$(mktemp -d)"
echo "extracting llvm-mingw…"
unzip -q "$MINGW_ARC" -d "$MINGW_TMP"
MINGW_ROOT="$(find "$MINGW_TMP" -maxdepth 1 -type d -name 'llvm-mingw-*' | head -1)"
[[ -n "$MINGW_ROOT" && -d "${MINGW_ROOT}/bin" ]] || {
  echo "llvm-mingw layout unexpected" >&2
  exit 1
}

# Flatten llvm-mingw to pack root (bin/include/lib/…).
cp -a "${MINGW_ROOT}/." "${STAGE}/"
rm -rf "$MINGW_TMP"

stage_cmake_from_archive "$CMAKE_ARC" "$STAGE" windows
stage_ninja "$NINJA_ARC" "$STAGE" ninja.exe
stage_zlib_mingw_windows "$STAGE"
stage_sdl3_mingw_windows "$STAGE"
stage_python_standalone "$STAGE" "x86_64-pc-windows-msvc"

cat >"${STAGE}/env.bat" <<'EOF'
@echo off
set "PACK_ROOT=%~dp0"
set "PACK_ROOT=%PACK_ROOT:~0,-1%"
echo ;%PATH%; | find /I ";%PACK_ROOT%\bin;" >nul
if errorlevel 1 set "PATH=%PACK_ROOT%\bin;%PATH%"
echo ;%PATH%; | find /I ";%PACK_ROOT%\python;" >nul
if errorlevel 1 set "PATH=%PACK_ROOT%\python;%PATH%"
set "CC=%PACK_ROOT%\bin\clang.exe"
set "CXX=%PACK_ROOT%\bin\clang++.exe"
set "AR=%PACK_ROOT%\bin\llvm-ar.exe"
set "RANLIB=%PACK_ROOT%\bin\llvm-ranlib.exe"
set "ZLIB_ROOT=%PACK_ROOT%"
set "RETCOMM_TOOLCHAIN_DIR=%PACK_ROOT%"
set "RETCOMM_PYTHON=%PACK_ROOT%\python\python.exe"
rem Do not put PACK_ROOT on CMAKE_PREFIX_PATH — mingw include/ poisons libc++.
if exist "%PACK_ROOT%\lib\cmake\SDL3\SDL3Config.cmake" (
  set "SDL3_DIR=%PACK_ROOT%\lib\cmake\SDL3"
) else if exist "%PACK_ROOT%\lib\cmake\SDL3\SDL3-config.cmake" (
  set "SDL3_DIR=%PACK_ROOT%\lib\cmake\SDL3"
)
EOF

cat >"${STAGE}/env.sh" <<'EOF'
#!/usr/bin/env bash
# For Git Bash / MSYS. Prefer env.bat from cmd.exe.
PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case ":${PATH}:" in
  *":${PACK_ROOT}/bin:"*) ;;
  *) export PATH="${PACK_ROOT}/bin${PATH:+:${PATH}}" ;;
esac
case ":${PATH}:" in
  *":${PACK_ROOT}/python:"*) ;;
  *) export PATH="${PACK_ROOT}/python${PATH:+:${PATH}}" ;;
esac
export CC="${PACK_ROOT}/bin/clang.exe"
export CXX="${PACK_ROOT}/bin/clang++.exe"
export AR="${PACK_ROOT}/bin/llvm-ar.exe"
export RANLIB="${PACK_ROOT}/bin/llvm-ranlib.exe"
export ZLIB_ROOT="${PACK_ROOT}"
export RETCOMM_TOOLCHAIN_DIR="${PACK_ROOT}"
export RETCOMM_PYTHON="${PACK_ROOT}/python/python.exe"
# Prefer SDL3_DIR / ZLIB_ROOT — never CMAKE_PREFIX_PATH=pack (libc++ / mingw include clash).
if [[ -f "${PACK_ROOT}/lib/cmake/SDL3/SDL3Config.cmake" ||
      -f "${PACK_ROOT}/lib/cmake/SDL3/SDL3-config.cmake" ]]; then
  export SDL3_DIR="${PACK_ROOT}/lib/cmake/SDL3"
fi
EOF
chmod +x "${STAGE}/env.sh"

cat >"${STAGE}/README.md" <<EOF
# ${PACK_ID} (${OS_TAG})

Self-contained Windows toolchain for RetComM / psxrecomp local builds:

- llvm-mingw ${LLVM_MINGW_TAG} (LLVM/Clang/LLD + mingw-w64 **UCRT** sysroot)
- CMake ${CMAKE_VERSION}
- Ninja ${NINJA_VERSION}
- zlib ${ZLIB_VERSION} (static \`libz.a\` + headers for \`find_package(ZLIB)\`)
- SDL3 ${SDL3_VERSION} (static \`libSDL3.a\` + CMake CONFIG for \`find_package(SDL3)\`)
- CPython ${PYTHON_VERSION} (python-build-standalone; no Store alias / system install)

No Visual Studio install required. Targets Windows 10+ (UCRT).

## Install (recommended)

From this extracted zip root — shared RetComM cache + user PATH (idempotent):

\`\`\`bat
install.bat
cmake --version
clang --version
\`\`\`

\`\`\`bat
uninstall.bat
\`\`\`

PowerShell: \`.\install.ps1\` / \`.\uninstall.ps1\`.

## Session-only (no PATH change)

\`\`\`bat
call env.bat
cmake --version
clang --version
\`\`\`

\`env.bat\` / \`env.sh\` prepend \`bin\\\` to \`PATH\` and set \`ZLIB_ROOT\` /
\`SDL3_DIR\` (not \`CMAKE_PREFIX_PATH\` — that breaks libc++ on this pack).

Pack version: ${PACK_VERSION}

Upstream: https://github.com/mstorsjo/llvm-mingw
EOF

write_meta "$STAGE" "$OS_TAG" "llvm-mingw-ucrt"
stage_bundle_scripts "$STAGE" windows

# Structure checks (cannot exec PE on Linux CI without wine).
[[ -f "${STAGE}/bin/clang.exe" ]]
[[ -f "${STAGE}/bin/clang++.exe" ]]
[[ -f "${STAGE}/bin/cmake.exe" ]]
[[ -f "${STAGE}/bin/ninja.exe" ]]
[[ -f "${STAGE}/bin/x86_64-w64-mingw32-clang.exe" ]] || \
  [[ -f "${STAGE}/bin/clang.exe" ]]
[[ -f "${STAGE}/include/zlib.h" ]]
[[ -f "${STAGE}/lib/libz.a" ]]
[[ -f "${STAGE}/x86_64-w64-mingw32/lib/libz.a" ]]
[[ -f "${STAGE}/lib/libSDL3.a" ]]
[[ -f "${STAGE}/lib/cmake/SDL3/SDL3Config.cmake" ]] || \
  [[ -f "${STAGE}/lib/cmake/SDL3/SDL3-config.cmake" ]]
[[ -d "${STAGE}/include/SDL3" ]]
[[ -f "${STAGE}/python/python.exe" ]]
[[ -f "${STAGE}/install.ps1" ]]
[[ -f "${STAGE}/uninstall.ps1" ]]
[[ -f "${STAGE}/install.bat" ]]
[[ -f "${STAGE}/uninstall.bat" ]]

make_zip "$STAGE" "$ZIP"
