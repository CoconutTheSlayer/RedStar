# PoseidonRust

Toolchain spike for the incremental C++ → Rust migration. Its only job is to
prove the build seam end to end:

```
Cargo (staticlib) ──Corrosion──> CMake target `PoseidonRust` ──> C++ engine
```

It is **not** a real module. It exposes a few trivial C-ABI functions
(`prs_add`, `prs_greet`/`prs_string_free`, `prs_abi_version`) that the
`RustSpike` executable (`apps/spikes/RustSpike`) calls and asserts on. That
executable is registered as the `RustSpike` CTest, so a green test means the
whole chain — Cargo build, static linking, C-ABI call, allocation hand-off —
works on this platform.

## Build

Enabled by default on this branch; toggle with `-DPOSEIDON_ENABLE_RUST=ON/OFF`.
Corrosion is fetched at configure time (needs network on first configure) and
drives `cargo` for you — no separate Rust build step.

```sh
cmake --build --preset <preset> --target RustSpike
ctest --preset <preset> -R RustSpike
cargo test --manifest-path engine/PoseidonRust/Cargo.toml   # Rust-side unit tests
```

## FFI conventions established here (reuse for every future module)

- **No panic across `extern "C"`** — every entry point wraps its body in
  `catch_unwind` and returns a benign sentinel (null / error code) on panic.
- **Allocation ownership is explicit** — Rust frees what Rust allocates
  (`prs_string_free`); C++ never frees a Rust pointer, and vice versa.
- **`unsafe` is quarantined** to the thin boundary functions.
- The C header is hand-written for now; switch to **cbindgen** before the first
  real module so the header can't drift from `src/lib.rs`.

## Next step

Replace this spike with the first real leaf module behind the same boundary —
the `PoseidonFormats` C API (P3D/PAA/PBO/RTM parsing) is the natural first
target; `mserver/Archive` already has a Rust PBO/LZSS implementation to draw on.
