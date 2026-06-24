# PoseidonArchive

The first **real** module of the C++ → Rust migration: a C ABI for reading
OFP/Poseidon PBO archives, so the engine can use the Rust PBO reader instead of
the C++ one.

It is a thin FFI wrapper — all the parsing lives in the standalone, safe
[`papa-bear-archive`](../../mserver/Archive) crate (byte-compatible PBO + LZSS,
`unsafe_code = "deny"`), which is already used by the mserver tooling. This crate
just marshals across the boundary, reusing the conventions proven by
[`PoseidonRust`](../PoseidonRust): no panic crosses `extern "C"`, allocations are
owned by their creator, `unsafe` is confined to the boundary, and the header is
cbindgen-generated.

## C ABI (`include/poseidon_archive.h`, generated)

```
PaPbo*      pa_pbo_open(const char* path);
PaPbo*      pa_pbo_open_bytes(const uint8_t* data, int len);
void        pa_pbo_close(PaPbo*);
int         pa_pbo_entry_count(const PaPbo*);
const char* pa_pbo_entry_name(const PaPbo*, int idx);   // owned by handle
int         pa_pbo_entry_size(const PaPbo*, int idx);   // decompressed size
int         pa_pbo_extract(const PaPbo*, int idx, uint8_t* buf, int buf_size);
const char* pa_last_error(void);                        // thread-local, never null
```

`pa_pbo_extract` with a null `buffer` returns the size without copying (query);
errors return -1 / null with a message in `pa_last_error`.

## Build & test

Built via Corrosion when `POSEIDON_ENABLE_RUST=ON`. The `PboReadSpike` CTest
(`apps/spikes/PboReadSpike`) opens `tests/fixtures/pbo/addon_fixture.pbo` and
verifies every entry extracts to its reported size.

```sh
cargo test --manifest-path engine/PoseidonArchive/Cargo.toml
ctest --preset <preset> -R PboReadSpike
```

## Status: the default PBO reader

`PoseidonFormats`' `pf_pbo_*` is now backed by this crate by default
(`POSEIDON_PBO_USE_RUST`, which defaults to `POSEIDON_ENABLE_RUST` — i.e. ON
wherever the Rust build is enabled; set it OFF to fall back to the C++ QFBank
path). The `PoseidonArchive.PboParity` test keeps guarding the two
implementations against each other: it links `PoseidonFormatsRef`, a reference
build pinned to the C++ path, so the comparison stays a real C++-vs-Rust check
regardless of the default. Parity is verified byte-for-byte on the bundled
fixtures and on real game data (set `POSEIDON_PBO_PARITY_DIR`).
