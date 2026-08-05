#!/usr/bin/env bash
# Install cmake-clang-v1 (macOS universal: CMake + Ninja) into the RetComM cache.
# Requires Xcode Command Line Tools for Apple Clang / SDK.
#
#   ./scripts/install_macos.sh
#   ./scripts/install_macos.sh --from-zip ~/Downloads/cmake-clang-v1-macos-universal.zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install_common.sh"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Note: Xcode Command Line Tools not found. This pack needs system clang."
  echo "      Run: xcode-select --install"
fi

parse_and_install macos-universal "$@"
