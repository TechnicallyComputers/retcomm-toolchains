#!/usr/bin/env bash
# Shared helpers for installing cmake-clang-v1 into the RetComM toolchain cache.
#
# Layout (matches RetComM + standalone setup hosts):
#   Windows: %LOCALAPPDATA%\retcomm\toolchains\<id>\<tag>\
#   Linux / macOS: ${XDG_DATA_HOME:-~/.local/share}/retcomm/toolchains/<id>/<tag>/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/pins.env"

DEFAULT_REPO="${RETCOMM_TOOLCHAIN_REPO:-TechnicallyComputers/retcomm-toolchains}"
CMAKE_BIN_NAME=cmake

retcomm_data_home() {
  if [[ -n "${RETCOMM_DATA_HOME:-}" ]]; then
    printf '%s\n' "${RETCOMM_DATA_HOME}"
    return
  fi
  if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    printf '%s\n' "${XDG_DATA_HOME}/retcomm"
    return
  fi
  printf '%s\n' "${HOME}/.local/share/retcomm"
}

pack_cache_root() {
  # Prefer an explicit override of the pack root (…/cmake-clang-v1).
  if [[ -n "${RETCOMM_TOOLCHAIN_CACHE:-}" ]]; then
    printf '%s\n' "${RETCOMM_TOOLCHAIN_CACHE}"
    return
  fi
  printf '%s\n' "$(retcomm_data_home)/toolchains/${PACK_ID}"
}

asset_for_os() {
  case "$1" in
    linux-x64) echo "${PACK_ID}-linux-x64.zip" ;;
    windows-x64) echo "${PACK_ID}-windows-x64.zip" ;;
    macos-universal|macos-arm64|macos-x64) echo "${PACK_ID}-macos-universal.zip" ;;
    *)
      echo "unknown os tag: $1" >&2
      return 1
      ;;
  esac
}

cmake_name_for_os() {
  case "$1" in
    windows-x64) echo cmake.exe ;;
    *) echo cmake ;;
  esac
}

pack_root_looks_usable() {
  local root="$1" cmake_name="$2"
  [[ -d "${root}/bin" && -f "${root}/bin/${cmake_name}" ]]
}

unwrap_pack_root() {
  local path="$1" cmake_name="$2"
  if pack_root_looks_usable "$path" "$cmake_name"; then
    printf '%s\n' "$path"
    return
  fi
  local kids=()
  local d
  shopt -s nullglob
  for d in "${path}"/*/; do
    [[ -d "$d" ]] || continue
    local base
    base="$(basename "$d")"
    [[ "$base" == .* ]] && continue
    kids+=("${d%/}")
  done
  shopt -u nullglob
  if [[ ${#kids[@]} -eq 1 ]] && pack_root_looks_usable "${kids[0]}" "$cmake_name"; then
    printf '%s\n' "${kids[0]}"
    return
  fi
  printf '%s\n' "$path"
}

read_pack_version() {
  local root="$1"
  local meta="${root}/retcomm-toolchain.json"
  [[ -f "$meta" ]] || { echo ""; return; }
  # Prefer python for reliable JSON; fall back to a light sed scrape.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("version","").strip())' "$meta" 2>/dev/null || true
    return
  fi
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" | head -1
}

sanitize_tag() {
  local s="$1"
  s="${s//[^A-Za-z0-9._-]/_}"
  printf '%s\n' "${s:-offline}"
}

find_local_dist_zip() {
  local os_tag="$1"
  local asset
  asset="$(asset_for_os "$os_tag")"
  local cand="${ROOT}/dist/${asset}"
  if [[ -f "$cand" ]]; then
    printf '%s\n' "$cand"
    return
  fi
  # Accept a uniquely matching glob under dist/
  local matches=()
  local f
  shopt -s nullglob
  case "$os_tag" in
    linux-x64) matches=("${ROOT}/dist/"${PACK_ID}*linux*.zip) ;;
    windows-x64) matches=("${ROOT}/dist/"${PACK_ID}*windows*.zip) ;;
    macos-* ) matches=("${ROOT}/dist/"${PACK_ID}*macos*.zip) ;;
  esac
  shopt -u nullglob
  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

download_release_zip() {
  local os_tag="$1" dest="$2"
  local asset repo url
  asset="$(asset_for_os "$os_tag")"
  repo="${DEFAULT_REPO}"
  url="https://github.com/${repo}/releases/latest/download/${asset}"
  mkdir -p "$(dirname "$dest")"
  echo "Downloading ${asset} from ${repo}…"
  if command -v gh >/dev/null 2>&1; then
    local dl_dir
    dl_dir="$(dirname "$dest")"
    rm -f "${dl_dir}/${asset}"
    gh release download -R "${repo}" -p "${asset}" -D "${dl_dir}" --clobber
    if [[ "$(realpath "${dl_dir}/${asset}")" != "$(realpath "$dest")" ]]; then
      mv -f "${dl_dir}/${asset}" "$dest"
    fi
  else
    command -v curl >/dev/null 2>&1 || { echo "need curl or gh to download" >&2; exit 1; }
    local curl_args=(-fL --retry 3 --retry-delay 2 -o "${dest}.partial")
    if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
      curl_args+=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}")
    fi
    curl "${curl_args[@]}" "$url"
    mv "${dest}.partial" "$dest"
  fi
}

extract_zip() {
  local zip_path="$1" dest="$2"
  mkdir -p "$dest"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip_path" -d "$dest"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$zip_path" "$dest"
  else
    echo "need unzip or python3 to extract ${zip_path}" >&2
    exit 1
  fi
}

set_latest_pointer() {
  local cache_root="$1" pack_root="$2"
  local latest="${cache_root}/latest"
  if [[ -e "$latest" || -L "$latest" ]]; then
    if [[ -L "$latest" || -f "$latest" ]]; then
      rm -f "$latest"
    else
      rm -rf "$latest"
    fi
  fi
  if ln -s "$pack_root" "$latest" 2>/dev/null; then
    return
  fi
  # Windows / some FS: copy as fallback (same as standalone ensure).
  cp -a "$pack_root" "$latest"
}

write_pack_stamp() {
  local dest="$1" tag="$2" asset="$3"
  cat >"${dest}/.retcomm-pack.json" <<EOF
{
  "id": "${PACK_ID}",
  "tag": "${tag}",
  "asset": "${asset}",
  "github": "${DEFAULT_REPO}",
  "installed_by": "retcomm-toolchains/scripts/install"
}
EOF
}

print_dev_howto() {
  local pack_root="$1" os_tag="$2" ver="$3" cache_root="${4:-}"
  if [[ -z "$cache_root" ]]; then
    cache_root="$(pack_cache_root)"
  fi
  cat <<EOF

Installed ${PACK_ID} ${ver} → ${pack_root}

This is the shared RetComM toolchain cache. RetComM, title setup wizards, and
standalone ensure-toolchain will reuse it (no second download).

Activate for this shell (recomp / CMake / Ninja development):

EOF
  if [[ "$os_tag" == windows-x64 ]]; then
    cat <<EOF
  # cmd.exe
  call "${pack_root}\\env.bat"

  # Git Bash / MSYS
  . "${pack_root}/env.sh"
EOF
  else
    cat <<EOF
  . "${pack_root}/env.sh"
  cmake --version
EOF
    if [[ "$os_tag" == linux-x64 ]]; then
      echo "  clang --version"
    elif [[ "$os_tag" == macos-* ]]; then
      cat <<EOF
  # macOS packs ship CMake + Ninja; Apple Clang / Xcode CLT required:
  xcode-select -p >/dev/null 2>&1 || xcode-select --install
  clang --version
EOF
    fi
  fi
  cat <<EOF

Optional overrides:
  export RETCOMM_TOOLCHAIN_DIR="${pack_root}"

Cache layout: ${cache_root}/<tag>/   (latest → current install)
EOF
}

install_pack() {
  local os_tag="$1"
  local from_zip="${2:-}"
  local download="${3:-0}"
  local force="${4:-0}"
  local prefix="${5:-}"

  local cmake_name asset zip_path
  cmake_name="$(cmake_name_for_os "$os_tag")"
  asset="$(asset_for_os "$os_tag")"

  local cache_root
  if [[ -n "$prefix" ]]; then
    cache_root="$prefix"
  else
    cache_root="$(pack_cache_root)"
  fi
  mkdir -p "$cache_root"

  if [[ -n "$from_zip" ]]; then
    zip_path="$(cd "$(dirname "$from_zip")" && pwd)/$(basename "$from_zip")"
    [[ -f "$zip_path" ]] || { echo "zip not found: $from_zip" >&2; exit 1; }
  elif [[ "$download" == "1" ]]; then
    zip_path="${cache_root}/.download/${asset}"
    download_release_zip "$os_tag" "$zip_path"
  else
    # Default: local dist/ if present, else download latest release.
    local local_zip
    local_zip="$(find_local_dist_zip "$os_tag" || true)"
    if [[ -n "$local_zip" ]]; then
      zip_path="$local_zip"
      echo "Using local pack: ${zip_path}"
    else
      zip_path="${cache_root}/.download/${asset}"
      download_release_zip "$os_tag" "$zip_path"
    fi
  fi

  local staging="${cache_root}/.staging-install"
  rm -rf "$staging"
  mkdir -p "$staging"
  echo "Extracting $(basename "$zip_path")…"
  extract_zip "$zip_path" "$staging"

  local root
  root="$(unwrap_pack_root "$staging" "$cmake_name")"
  if ! pack_root_looks_usable "$root" "$cmake_name"; then
    echo "error: zip missing bin/${cmake_name}: ${zip_path}" >&2
    exit 1
  fi

  local ver tag dest
  ver="$(read_pack_version "$root")"
  tag="$(sanitize_tag "${ver:-offline}")"
  dest="${cache_root}/${tag}"

  if [[ -e "$dest" && "$force" != "1" ]]; then
    if pack_root_looks_usable "$(unwrap_pack_root "$dest" "$cmake_name")" "$cmake_name"; then
      echo "Already installed at ${dest} (pass --force to replace)."
      set_latest_pointer "$cache_root" "$(unwrap_pack_root "$dest" "$cmake_name")"
      print_dev_howto "$(unwrap_pack_root "$dest" "$cmake_name")" "$os_tag" "${ver:-$tag}" "$cache_root"
      rm -rf "$staging"
      return 0
    fi
  fi

  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  if [[ "$root" == "$staging" ]]; then
    mv "$staging" "$dest"
  else
    # Nested single-dir zip: move the usable child up to the tag dir.
    mv "$root" "$dest"
    rm -rf "$staging"
  fi

  root="$(unwrap_pack_root "$dest" "$cmake_name")"
  write_pack_stamp "$dest" "$tag" "$(basename "$zip_path")"
  set_latest_pointer "$cache_root" "$root"

  # Light smoke: cmake must run (skip PE cmake on non-Windows hosts).
  if [[ "$os_tag" != windows-x64 || "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* ]]; then
    if [[ -x "${root}/bin/${cmake_name}" || -f "${root}/bin/${cmake_name}" ]]; then
      "${root}/bin/${cmake_name}" --version | head -1 || true
    fi
  fi

  print_dev_howto "$root" "$os_tag" "${ver:-$tag}" "$cache_root"
}

usage_install() {
  local me="$1" os_tag="$2"
  cat <<EOF
Usage: ${me} [options]

Install the ${PACK_ID} (${os_tag}) pack into the shared RetComM toolchain cache
so RetComM, title wizards, and local recomp builds all share one toolchain.

Options:
  --from-zip PATH   Install from a local cmake-clang-v1-*.zip
  --download        Always fetch the latest GitHub release asset
  --force           Replace an existing matching <tag>/ directory
  --prefix DIR      Install under DIR instead of the default cache
                    (default: \${XDG_DATA_HOME:-~/.local/share}/retcomm/toolchains/${PACK_ID})
  -h, --help        Show this help

With no zip flags: use dist/$(asset_for_os "$os_tag") if present, otherwise download.

Env:
  RETCOMM_DATA_HOME         Override ~/.local/share/retcomm
  RETCOMM_TOOLCHAIN_CACHE   Override …/toolchains/${PACK_ID}
  RETCOMM_TOOLCHAIN_REPO    GitHub owner/name (default ${DEFAULT_REPO})
  GH_TOKEN / GITHUB_TOKEN   Optional for higher rate limits
EOF
}

parse_and_install() {
  local os_tag="$1"
  shift
  local from_zip="" download=0 force=0 prefix=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage_install "$(basename "$0")" "$os_tag"
        exit 0
        ;;
      --from-zip)
        from_zip="${2:?--from-zip needs a path}"
        shift 2
        ;;
      --download)
        download=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      --prefix)
        prefix="${2:?--prefix needs a directory}"
        shift 2
        ;;
      *)
        echo "unknown option: $1" >&2
        usage_install "$(basename "$0")" "$os_tag" >&2
        exit 2
        ;;
    esac
  done
  install_pack "$os_tag" "$from_zip" "$download" "$force" "$prefix"
}
