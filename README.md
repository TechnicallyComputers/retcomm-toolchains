# retcomm-toolchains

[![GitHub downloads (all assets, all releases)](https://img.shields.io/github/downloads/TechnicallyComputers/RetComM-toolchains/total)](https://github.com/TechnicallyComputers/RetComM-toolchains/releases)
[![GitHub downloads (latest release)](https://img.shields.io/github/downloads/TechnicallyComputers/RetComM-toolchains/latest/total)](https://github.com/TechnicallyComputers/RetComM-toolchains/releases/latest)
[![GitHub release](https://img.shields.io/github/v/release/TechnicallyComputers/RetComM-toolchains)](https://github.com/TechnicallyComputers/RetComM-toolchains/releases/latest)

Shared, fetch-on-demand toolchain packs for
[RetComM](https://github.com/TechnicallyComputers/RetComM-Launcher) and
standalone recomp setup hosts (psxrecomp / snesrecomp / …).

Packs are **not** shipped inside lean game zips. Clients download (or accept an
offline zip) into one shared cache used by every title and by the launcher.

## Shared cache

| OS | Path |
|----|------|
| Windows | `%LOCALAPPDATA%\retcomm\toolchains\<id>\<tag>\` |
| Linux / macOS | `~/.local/share/retcomm/toolchains/<id>/<tag>/` (or `$XDG_DATA_HOME/retcomm/…`) |

Example: `…/retcomm/toolchains/cmake-clang-v1/1.0.3/` plus an optional `latest`
pointer for simple resolvers.

| Override | Meaning |
|----------|---------|
| `RETCOMM_TOOLCHAIN_DIR` | Use this unpacked pack root (skip download) |
| `RETCOMM_TOOLCHAIN_MIN_VERSION` | Semver floor for standalone ensure (wizard / CLI) |
| `RETCOMM_DATA_HOME` | Override the `…/retcomm` data root used by install scripts |
| `RETCOMM_TOOLCHAIN_CACHE` | Override `…/toolchains/cmake-clang-v1` for install scripts |

Legacy `%LOCALAPPDATA%\psxrecomp\toolchains\…` is still discovered and migrated
into the `retcomm` tree on ensure.

Offline: pass a `cmake-clang-v1-*.zip` to the setup wizard / `ensure-toolchain
--from-zip`; it unpacks into the same shared path.

## Install for development (recommended)

### From a release zip (easiest)

Each GitHub Release asset ships `install` / `uninstall` at the **zip root**.
Extract, then run from that directory — this copies the pack into the shared
RetComM cache and adds `latest/bin` to your login PATH (**idempotent** add;
uninstall removes the entry even if it was already gone).

```bash
# Linux / macOS
unzip cmake-clang-v1-linux-x64.zip -d cmake-clang-v1   # or *-macos-universal.zip
cd cmake-clang-v1
./install.sh
cmake --version

./uninstall.sh          # remove cache copy + PATH hook
```

```bat
REM Windows — extract zip, then:
install.bat
cmake --version
uninstall.bat
```

(`install.ps1` / `uninstall.ps1` are also in the Windows zip.)

### From this repo (download or local `dist/`)

```bash
./scripts/install_linux_x64.sh
./scripts/install_macos.sh
```

```powershell
.\scripts\install_windows_x64.ps1
```

| Flag | Meaning |
|------|---------|
| `--from-zip PATH` / `-FromZip` | Offline install from a release zip |
| `--download` / `-Download` | Always fetch latest (ignore local `dist/`) |
| `--force` / `-Force` | Replace an existing matching `<tag>/` dir |
| `--prefix DIR` / `-Prefix` | Custom cache root (still `<tag>/` underneath) |

RetComM / standalone wizards find the shared cache automatically after install.
Session-only alternative (no PATH change): source `env.sh` / `call env.bat`
from the pack root.

## Versioning

Each pack ships `retcomm-toolchain.json`:

```json
{
  "id": "cmake-clang-v1",
  "version": "1.0.4",
  "os": "windows-x64",
  "kind": "llvm-mingw-ucrt",
  "pins": { "cmake": "…", "ninja": "…", "zlib": "…", "sdl3": "…" }
}
```

- Pack semver is [`VERSION`](VERSION); bump it when the zip contents change.
- GitHub release tags should match (e.g. `v1.0.4` / `1.0.4`).
- Clients keep side‑by‑side `<tag>/` dirs so older titles can keep working while
  newer ones require a higher floor.

### Who sets the minimum?

| Layer | Where | Scope |
|-------|--------|--------|
| **Catalog title** | `build.toolchain.min_version` in [retcomm-catalog](https://github.com/TechnicallyComputers/retcomm-catalog) | That title when RetComM installs / builds |
| **Engine / wizard** | None by default — download GitHub `/releases/latest` | Standalone setup wizard / `ensure-toolchain` |
| **Override** | `RETCOMM_TOOLCHAIN_MIN_VERSION`, `ensure-toolchain --min-version` | Session / CI (optional floor) |

Different titles (and engines) can require different floors against the **same**
pack id. RetComM picks the newest cached pack that satisfies the title’s
`min_version`, or downloads a newer release and leaves older tags on disk.

Mechanism (compare / ensure / replace) lives in RetComM and the engine hosts —
not in per-game `game.toml`.

## Pack id: `cmake-clang-v1`

| Asset | Contents |
|-------|----------|
| `cmake-clang-v1-linux-x64.zip` | Pruned LLVM/Clang + lld, jammy **build sysroot**, bundled `libxml2.so.2` + ICU 70, `clang.cfg` → `-fuse-ld=lld --rtlib=compiler-rt --sysroot=…`, CMake, Ninja, ccache, static SDL3 (built on jammy-compatible glibc) + zlib, embeddable CPython |
| `cmake-clang-v1-windows-x64.zip` | [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) UCRT + CMake + Ninja + ccache + static zlib + static SDL3 + embeddable CPython |
| `cmake-clang-v1-macos-universal.zip` | CMake + Ninja + ccache + embeddable CPython (arm64+x64); **requires Xcode CLT** (system clang); SDL3 via FetchContent / system |

Layout (client contract):

```
bin/cmake  bin/ninja  bin/ccache  bin/clang …   # compilers vary by OS
python/                             # CPython (PBS); Windows: python.exe, Unix: bin/python3
deps/include/ zlib.h + SDL3/…       # 1.0.9+: host libs (not mingw include/)
deps/lib/ libz.a libSDL3.a cmake/SDL3/
env.sh                              # Windows also has env.bat (ZLIB_ROOT + SDL3_DIR → deps/)
install.sh / uninstall.sh           # Unix zip root (PATH + shared cache)
install.ps1 / uninstall.ps1         # Windows (+ install.bat / uninstall.bat)
retcomm-toolchain.json
README.md
```

Pins live in [`pins.env`](pins.env).

## Build locally

```bash
./scripts/package_linux_x64.sh
./scripts/package_windows_x64.sh
./scripts/package_macos.sh macos-universal
# → dist/cmake-clang-v1-*.zip
```

Downloads cache under `.cache/downloads/` (`RETCOMM_TC_CACHE` to override).

## Catalog

Point title `build.toolchain` at this repo:

```json
"toolchain": {
  "id": "cmake-clang-v1",
  "github": "TechnicallyComputers/retcomm-toolchains",
  "min_version": "1.0.6",
  "asset_glob": {
    "linux": "*cmake-clang-v1*linux*",
    "windows": "*cmake-clang-v1*windows*",
    "macos": "*cmake-clang-v1*macos*"
  }
}
```

Omit `min_version` when any cached usable pack is fine. Raise it when a title
needs a newer dependency (e.g. Linux jammy-compatible **SDL3** in `1.0.14+`,
Linux jammy **build sysroot** / SteamOS-ready in
`1.0.12+`, Linux `--rtlib=compiler-rt` / no host GCC CRT in
`1.0.11+`, `deps/` layout in `1.0.9+`, prebuilt SDL3 in
`1.0.7+`, embeddable Python in `1.0.6+`, Linux ICU 70 in `1.0.5+`,
LTO/`libxml2` in `1.0.4+`, Windows zlib in `1.0.3+`).

**1.0.14+** (Linux): assemble packs on **ubuntu-22.04** so prebuilt
`deps/libSDL3.a` matches the jammy sysroot glibc (2.35). 1.0.12–1.0.13 built
SDL3 on ubuntu-24.04 and embedded `__isoc23_*` / `strlcpy` / `wcslcpy`, which
fail to link on Debian and SteamOS against the jammy sysroot. Packaging smoke
rejects those undefs; SteamOS still uses the same jammy `--sysroot` (unchanged).

**1.0.12+** (Linux): ships an Ubuntu jammy amd64 **build sysroot** under
`sysroot/` (glibc + linux-api + libstdc++ + OpenGL headers and linker stubs).
`clang.cfg` sets `--sysroot=<CFGDIR>/../sysroot`; RetComM passes
`-DCMAKE_SYSROOT`. SteamOS / Deck installs no longer need `steamos-readonly`
or `base-devel`. Also stages zlib into `deps/` like Windows.

**1.0.11+** (Linux): `clang.cfg` adds `--rtlib=compiler-rt` so links use the
pack’s `clang_rt.crtbegin` / `libclang_rt.builtins` instead of host GCC
`crtbeginS.o` / `-lgcc`. Fixes cmake configure on SteamOS / Deck and other
hosts without `gcc` / `base-devel`. C++ still needs host **libstdc++**
(headers + shared lib) until **1.0.12**.

**1.0.9+** installs zlib + SDL3 under **`deps/`** so `find_package` never
`-isystem`s the Windows llvm-mingw top-level `include/` (which poisons libc++
`<cmath>` / `<cwchar>`). Clients set `ZLIB_ROOT=<pack>/deps` and
`SDL3_DIR=<pack>/deps/lib/cmake/SDL3`. Do **not** put the pack root on
`CMAKE_PREFIX_PATH` or `ZLIB_ROOT`.

**1.0.7–1.0.8** shipped the same static SDL3 at pack-root `lib/cmake/SDL3`
(and Windows zlib at pack-root `include/`). Those packs skip FetchContent’s
hundreds of `Looking for …` probes, but Windows C++ titles should upgrade to
`1.0.9+` for the `deps/` split.

Linux packs from **1.0.4** ship `libxml2.so.2` and default clang to
`-fuse-ld=lld` (via `bin/clang.cfg`) so Release IPO/`-flto=thin` works without
`LLVMgold.so` or a host `libxml2.so.2`. **1.0.5+** also bundles
`libicuuc.so.70` / `libicudata.so.70` (Ubuntu jammy) so `ld.lld` runs on hosts
that only ship newer ICU SONAMEs (Fedora/Cachy ICU 78). `env.sh` prepends pack
`lib/` to `LD_LIBRARY_PATH`; `patchelf` sets `$ORIGIN/../lib` on `lld` /
`ld.lld`. **1.0.6+** ships [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
CPython under `python/` so RetComM generate does not need a system Python
(Windows Store alias stubs included). Older caches still work: RetComM can
fetch the same PBS build into `toolchains/python-standalone/` on demand.

## License / redistribution

This repository’s scripts are MIT. Packaged binaries are redistributed under
their upstream licenses (LLVM Apache-2.0 with LLVM exceptions, Kitware BSD,
Ninja Apache-2.0, zlib, ICU Unicode License, CPython PSF, mingw-w64 various).
See [`NOTICE`](NOTICE).
