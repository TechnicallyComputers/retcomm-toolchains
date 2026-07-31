# retcomm-toolchains

Shared, fetch-on-demand toolchain packs for [RetComM](https://github.com/TechnicallyComputers/RetComM-Launcher)
and standalone recomp setup hosts (psxrecomp / snesrecomp).

Game release zips **do not** embed these packs. RetComM downloads them into
`~/.local/share/retcomm/toolchains/<id>/<tag>/` (override: `RETCOMM_TOOLCHAIN_DIR`)
and reuses them across titles.

## Pack id: `cmake-clang-v1`

| Asset | Contents |
|-------|----------|
| `cmake-clang-v1-linux-x64.zip` | Pruned LLVM/Clang + lld, CMake, Ninja |
| `cmake-clang-v1-windows-x64.zip` | [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) UCRT + CMake + Ninja |
| `cmake-clang-v1-macos-universal.zip` | CMake + Ninja; **requires Xcode CLT** (system clang) |

Layout (RetComM contract):

```
bin/cmake  bin/ninja  bin/clang …   # compilers vary by OS
env.sh                              # Windows also has env.bat
retcomm-toolchain.json
README.md
```

Pins live in [`pins.env`](pins.env); pack semver in [`VERSION`](VERSION).

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
  "asset_glob": {
    "linux": "*cmake-clang-v1*linux*",
    "windows": "*cmake-clang-v1*windows*",
    "macos": "*cmake-clang-v1*macos*"
  }
}
```

Linux packs include `lld` but `env.sh` does **not** force `-fuse-ld=lld`
(official LLVM lld may need `libxml2.so.2`). The system linker is the default;
opt in with `LDFLAGS=-fuse-ld=lld` if your host has a compatible libxml2.

## License / redistribution

This repository’s scripts are MIT. Packaged binaries are redistributed under
their upstream licenses (LLVM Apache-2.0 with LLVM exceptions, Kitware BSD,
Ninja Apache-2.0, mingw-w64 various). See [`NOTICE`](NOTICE).
