# retcomm-toolchains

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

Legacy `%LOCALAPPDATA%\psxrecomp\toolchains\…` is still discovered and migrated
into the `retcomm` tree on ensure.

Offline: pass a `cmake-clang-v1-*.zip` to the setup wizard / `ensure-toolchain
--from-zip`; it unpacks into the same shared path.

## Versioning

Each pack ships `retcomm-toolchain.json`:

```json
{
  "id": "cmake-clang-v1",
  "version": "1.0.4",
  "os": "windows-x64",
  "kind": "llvm-mingw-ucrt",
  "pins": { "cmake": "…", "ninja": "…", "zlib": "…" }
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
| **Engine default** | Setup host / `toolchain_pack` in the engine (e.g. psxrecomp → `1.0.4` for Linux LTO deps + Windows zlib) | Standalone wizard for that engine |
| **Override** | `RETCOMM_TOOLCHAIN_MIN_VERSION`, `ensure-toolchain --min-version` | Session / CI |

Different titles (and engines) can require different floors against the **same**
pack id. RetComM picks the newest cached pack that satisfies the title’s
`min_version`, or downloads a newer release and leaves older tags on disk.

Mechanism (compare / ensure / replace) lives in RetComM and the engine hosts —
not in per-game `game.toml`.

## Pack id: `cmake-clang-v1`

| Asset | Contents |
|-------|----------|
| `cmake-clang-v1-linux-x64.zip` | Pruned LLVM/Clang + lld, bundled `libxml2.so.2`, `clang.cfg` → `-fuse-ld=lld`, CMake, Ninja |
| `cmake-clang-v1-windows-x64.zip` | [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) UCRT + CMake + Ninja + static zlib |
| `cmake-clang-v1-macos-universal.zip` | CMake + Ninja; **requires Xcode CLT** (system clang) |

Layout (client contract):

```
bin/cmake  bin/ninja  bin/clang …   # compilers vary by OS
include/ zlib.h zconf.h             # Windows: static zlib for find_package(ZLIB)
lib/libz.a
env.sh                              # Windows also has env.bat (sets ZLIB_ROOT)
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
  "min_version": "1.0.4",
  "asset_glob": {
    "linux": "*cmake-clang-v1*linux*",
    "windows": "*cmake-clang-v1*windows*",
    "macos": "*cmake-clang-v1*macos*"
  }
}
```

Omit `min_version` when any cached usable pack is fine. Raise it when a title
needs a newer dependency (e.g. Linux LTO/`libxml2` in `1.0.4+`, Windows zlib in
`1.0.3+`).

Linux packs from **1.0.4** ship `libxml2.so.2` and default clang to
`-fuse-ld=lld` (via `bin/clang.cfg`) so Release IPO/`-flto=thin` works without
`LLVMgold.so` or a host `libxml2.so.2`. `env.sh` also prepends pack `lib/` to
`LD_LIBRARY_PATH`.

## License / redistribution

This repository’s scripts are MIT. Packaged binaries are redistributed under
their upstream licenses (LLVM Apache-2.0 with LLVM exceptions, Kitware BSD,
Ninja Apache-2.0, zlib, mingw-w64 various). See [`NOTICE`](NOTICE).
