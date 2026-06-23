// PboReadSpike — end-to-end proof of the first real C++ -> Rust module: opens a
// real PBO fixture through PoseidonArchive (backed by the Rust papa-bear-archive
// crate), lists its entries, and verifies each extracts to the reported size.
// Exits non-zero on any mismatch so it doubles as the PboReadSpike CTest.
//
// FIXTURE_PBO is the absolute path to the test fixture, injected by CMake.
#include "poseidon_archive.h"

#include <cstdio>
#include <vector>

int main() {
    PaPbo* pbo = pa_pbo_open(FIXTURE_PBO);
    if (pbo == nullptr) {
        std::fprintf(stderr, "pa_pbo_open(%s) failed: %s\n", FIXTURE_PBO,
                     pa_last_error());
        return 1;
    }

    int failures = 0;
    const int count = pa_pbo_entry_count(pbo);
    if (count <= 0) {
        std::fprintf(stderr, "entry_count = %d (expected > 0)\n", count);
        ++failures;
    }

    for (int i = 0; i < count; ++i) {
        const char* name = pa_pbo_entry_name(pbo, i);
        const int size = pa_pbo_entry_size(pbo, i);
        if (name == nullptr || size < 0) {
            std::fprintf(stderr, "entry %d: bad name/size\n", i);
            ++failures;
            continue;
        }
        // Size query (null buffer) must agree with entry_size.
        if (pa_pbo_extract(pbo, i, nullptr, 0) != size) {
            std::fprintf(stderr, "entry %d (%s): size query disagrees\n", i, name);
            ++failures;
        }
        // Actual extraction must fill exactly `size` bytes.
        std::vector<unsigned char> buf(static_cast<size_t>(size));
        const int got = pa_pbo_extract(pbo, i, buf.data(), size);
        if (got != size) {
            std::fprintf(stderr, "entry %d (%s): extract got %d want %d: %s\n", i,
                         name, got, size, pa_last_error());
            ++failures;
        }
        std::printf("  [%d] %-32s %d bytes\n", i, name, size);
    }

    pa_pbo_close(pbo);

    if (failures == 0) {
        std::printf("PboReadSpike: read %d entries from PBO via Rust OK\n", count);
    }
    return failures == 0 ? 0 : 1;
}
