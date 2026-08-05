#!/usr/bin/env bash
# Install cmake-clang-v1 (Linux x64) into the shared RetComM toolchain cache.
#
#   ./scripts/install_linux_x64.sh
#   ./scripts/install_linux_x64.sh --from-zip ~/Downloads/cmake-clang-v1-linux-x64.zip
#   ./scripts/install_linux_x64.sh --download --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install_common.sh"

parse_and_install linux-x64 "$@"
