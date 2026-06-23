# Arma: Cold War Assault - Remastered

This repository holds the engine and game source code (codename *Poseidon*) behind *Arma: Cold War Assault* — the game first released in 2001 as *Operation Flashpoint: Cold War Crisis*. That release launched Bohemia Interactive and began the technology lineage that later grew into Real Virtuality, Arma, and Enfusion. The code has been modernized to C++20, built with CMake and Clang, with cross-platform support for Windows x64 and Linux x64.
Bohemia Interactive is releasing it to the community that has kept this game alive for more than two decades — to study it, build on it, fix it, and create from it. Three things are worth keeping separate:

**Source code (this repository)**

The engine and game executables, licensed under GPL-3.0-or-later with additional terms under Section 7. You may use, study, modify, and redistribute it, provided it stays GPL and you follow those terms.

**The name and brand**

"ARMA", "Operation Flashpoint", and the logos are *not* granted. The trademarks stay with their owners ("ARMA" is Bohemia Interactive's). A fork must be renamed and must not present itself as "Arma" or as an official Bohemia Interactive product.

**Game data (separate)**

Models, textures, sounds, missions, and voices. These are not in this repository and are not GPL; they ship separately under the APL-SA license. A free Demo is available on Steam.

In short: the code is free software, the name is not, and the game data comes separately. This license covers the source code only and grants no rights to the trademarks.


## Quick Start

```sh
cmake --preset win-x64-clang-rwdi
cmake --build build/win-x64-clang-rwdi
```

On GNU/Linux, use the matching `linux-x64-clang-rwdi` preset. On macOS (Apple
Silicon), use `mac-arm64-clang-rwdi` — see [Building and running on macOS](#building-and-running-on-macos-apple-silicon).

## Building and running on macOS (Apple Silicon)

The engine builds and runs natively on Apple Silicon (arm64) Macs against an
OpenGL 4.1 Core context (macOS's GL ceiling), with SDL3 for windowing and
OpenAL Soft for audio. The macOS preset, toolchain, and vcpkg triplet live
under `cmake/` (`mac-arm64-clang`, `mac-arm64-clang.cmake`, `arm64-osx-clang`).

> Intel Macs are untracked: the build is fixed to `arm64`. macOS OpenGL is
> deprecated by Apple but still functional through its GL-on-Metal layer.

### 1. Prerequisites

```sh
xcode-select --install                 # Apple Clang + macOS SDK (libc++, ld64)
brew install cmake ninja ccache pkg-config clang-format

# vcpkg (any location); export VCPKG_ROOT so the presets find it
git clone https://github.com/microsoft/vcpkg "$HOME/vcpkg"
"$HOME/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
export VCPKG_ROOT="$HOME/vcpkg"        # add to your shell profile to persist
```

`ninja` and `ccache` are required by the shared preset; `pkg-config` and
`clang-format` are required by vcpkg ports and the CMake `Format` target.

### 2. Build

```sh
cmake --preset mac-arm64-clang-rwdi          # configures + builds all vcpkg deps from source (first run is slow)
cmake --build build/mac-arm64-clang-rwdi --target PoseidonGame
```

The native arm64 binary lands at
`build/mac-arm64-clang-rwdi/apps/cwr/Game/PoseidonGame`, and the LGPL
`libopenal.1.dylib` is copied next to it automatically.

### 3. Get the game data (free, via Steam)

The compiled binary needs **Remaster** game data — the `cwr_*` fonts and menu
world the engine expects ship with *Arma: Cold War Assault Remastered*, not with
the older *Arma: Cold War Assault* re-release. The free
[Remaster Demo](https://store.steampowered.com/app/4819000) (app id `4819000`)
provides compatible data.

The Demo has no macOS depot, so download its (platform-agnostic) data files with
[SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD), forcing the
Windows depot — you only need the data, not the bundled Windows executable:

```sh
brew install --cask steamcmd
steamcmd +@sSteamCmdForcePlatformType windows \
         +force_install_dir "$HOME/cwa-remaster" \
         +login YOUR_STEAM_USERNAME \
         +app_update 4819000 validate +quit
```

Enter your Steam password (and Steam Guard code) when prompted. This installs the
data into `~/cwa-remaster`. The full retail Remaster data works the same way —
point `-C` (below) at whichever data directory you have.

### 4. Run

```sh
./run-mac.sh                                  # launches windowed against ~/cwa-remaster
# or directly:
build/mac-arm64-clang-rwdi/apps/cwr/Game/PoseidonGame -C ~/cwa-remaster --window
```

Useful flags: `--fullscreen` (drop `--window`), `--fps` (frame-rate overlay),
`--help` / `--help-full` for the rest. `-C` / `--work-dir` points the engine at
the game-data directory (the one containing `DTA/`, `AddOns/`, `Worlds/`, etc.).

## Layout

- [Apps](apps/README.md) - executable targets
- [Engine](engine/README.md) - engine libraries and Rust Trident tooling
- [Master server tools](mserver/README.md) - Rust service and CLI crates
- [Tests](tests/README.md) - test source trees; CI currently compiles them only
- `cmake/` - presets, toolchains, vcpkg triplets, and overlay ports
- `docker/` - container support for service and runtime environments
- `packages/` - ignored local game data staging area
- `resources/` - application icon resources
- `thirdparty/` - vendored third-party headers and sources

## Project Notes

- [Contributing](CONTRIBUTING.md)
- [Credits](CREDITS.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Vendored dependencies](thirdparty/README.md)

## License

The source in this repository is licensed under the **GNU General Public License
v3.0 *or later***, with additional terms under **Section 7** of the GPL. See [`LICENSE`](LICENSE) for the
full text.
This license does not grant you any right to use "ARMA" or any other Bohemia Interactive trademark.

The [`thirdparty/`](thirdparty) directory is **excluded** from the project's GPL
license: it contains vendored third-party code (glad, the RenderDoc API header)
under their own respective licenses — see [`thirdparty/README.md`](thirdparty/README.md).
Dependencies pulled in via vcpkg ([`vcpkg.json`](vcpkg.json)) likewise remain under
their own licenses.

*"ARMA" is a registered trademark of BOHEMIA INTERACTIVE a.s. "OPERATION FLASHPOINT" is a registered trademark of Electronic Arts Inc.
See [`LICENSE`](LICENSE) for information concerning trademarks. This credits file is
informational and does not constitute any grant and/or waiver of rights.*

### Game data / assets — Arma Public License Share Alike (APL-SA)

Game data and assets (models, textures, sounds, missions, etc.) are **not part of
this repository** and are **not** covered by the GPL. They are released separately
by Bohemia Interactive under the **Arma Public License Share Alike (APL-SA)**:

- APL-SA license text: <https://www.bohemia.net/community/licenses/arma-public-license-share-alike>

### Getting game data to run what you build

The compiled binaries need game data to run. You can obtain the **free Demo game
data** on Steam:

- *Arma: Cold War Assault Remastered* Demo on Steam: <https://store.steampowered.com/app/4819000>

The full game data ships with the retail game. Whatever you do with assets is
governed by the APL-SA linked above; whatever you do with this source is governed by
the GPL with additional terms per Section 7 in [`LICENSE`](LICENSE).


## Contributing

This is a **locked** repository: pull requests are not accepted here, and this
repository will not be continuously updated.
Issues are only for bugs in official Bohemia Interactive builds distributed on
Steam. For ideas, development builds, ports, and community work, fork the code or
join the community continuation. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for more information.
