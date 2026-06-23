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

## Toward parity

This maps onto the `pf_pbo_*` subset of `engine/PoseidonFormats/PoseidonFormats.h`.
The natural next steps are wiring an actual engine call site (or the
`PoseidonFormats` PBO path) to these functions and adding a differential test
that reads the same archives through both the C++ and Rust readers to prove
byte-for-byte parity before switching the default.
