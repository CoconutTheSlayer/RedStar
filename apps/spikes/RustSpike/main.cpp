// RustSpike — minimal end-to-end proof that the C++ build can call into the
// Rust staticlib over the C ABI. Exercises a numeric round-trip, a string
// round-trip with Rust-owned allocation, and the ABI handshake. Exits non-zero
// on any mismatch so it doubles as the `RustSpike` CTest.
#include "poseidon_rust.h"

#include <cstdio>
#include <cstring>

int main() {
    int failures = 0;

    if (prs_abi_version() != PRS_ABI_VERSION) {
        std::fprintf(stderr, "ABI mismatch: crate=%d header=%d\n",
                     prs_abi_version(), PRS_ABI_VERSION);
        ++failures;
    }

    if (prs_add(2, 3) != 5) {
        std::fprintf(stderr, "prs_add(2,3) = %d, expected 5\n", prs_add(2, 3));
        ++failures;
    }

    char* greeting = prs_greet("Poseidon");
    if (greeting == nullptr ||
        std::strcmp(greeting, "Hello from Rust, Poseidon!") != 0) {
        std::fprintf(stderr, "prs_greet returned: %s\n",
                     greeting ? greeting : "(null)");
        ++failures;
    }
    prs_string_free(greeting);  // null-safe

    if (failures == 0) {
        std::puts("RustSpike: C++ -> Rust FFI round-trip OK");
    }
    return failures == 0 ? 0 : 1;
}
