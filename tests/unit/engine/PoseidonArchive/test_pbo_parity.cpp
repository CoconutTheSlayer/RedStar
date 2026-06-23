// PBO reader parity test — the C++ reader (PoseidonFormats' pf_pbo_* over QFBank)
// and the Rust reader (PoseidonArchive's pa_pbo_*) must agree, for every archive,
// on the entry set and on byte-for-byte identical decompressed contents. This is
// the regression gate guarding any switch of an engine call site to Rust.
//
// Fixtures: the bundled tree (FIXTURES_DIR, injected by CMake) is always scanned.
// Set POSEIDON_PBO_PARITY_DIR to additionally scan an external directory (e.g. a
// game-data install) for broader, real-world coverage without rebuilding.
//
// NOTE: keep this comparing the two implementations — build with the default
// POSEIDON_PBO_USE_RUST=OFF so pf_pbo_* is the C++ path. With the option ON both
// sides are Rust and the comparison is trivially satisfied.
#include "PoseidonFormats.h"
#include "poseidon_archive.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
using EntryMap = std::map<std::string, Bytes>;

// OFP paths are case-insensitive and use backslashes internally; normalise so the
// readers' naming conventions don't cause spurious mismatches. Content is always
// compared raw.
static std::string normalize(const char* raw) {
    std::string s = raw ? raw : "";
    for (char& c : s) {
        if (c == '\\') c = '/';
        else c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

static EntryMap readWithCpp(const std::string& path, int& err) {
    EntryMap out;
    PF_HANDLE pbo = pf_pbo_open(path.c_str());
    if (!pbo) {
        std::fprintf(stderr, "  C++  open failed: %s\n", pf_last_error());
        ++err;
        return out;
    }
    const int n = pf_pbo_entry_count(pbo);
    for (int i = 0; i < n; ++i) {
        const std::string name = normalize(pf_pbo_entry_name(pbo, i));
        const int size = pf_pbo_entry_size(pbo, i);
        Bytes buf(size > 0 ? static_cast<size_t>(size) : 0);
        const int got = pf_pbo_extract(pbo, i, buf.data(), size);
        buf.resize(got > 0 ? static_cast<size_t>(got) : 0);
        out[name] = std::move(buf);
    }
    pf_pbo_close(pbo);
    return out;
}

static EntryMap readWithRust(const std::string& path, int& err) {
    EntryMap out;
    PaPbo* pbo = pa_pbo_open(path.c_str());
    if (!pbo) {
        std::fprintf(stderr, "  Rust open failed: %s\n", pa_last_error());
        ++err;
        return out;
    }
    const int n = pa_pbo_entry_count(pbo);
    for (int i = 0; i < n; ++i) {
        const std::string name = normalize(pa_pbo_entry_name(pbo, i));
        const int size = pa_pbo_entry_size(pbo, i);
        Bytes buf(size > 0 ? static_cast<size_t>(size) : 0);
        const int got = pa_pbo_extract(pbo, i, buf.data(), size);
        buf.resize(got > 0 ? static_cast<size_t>(got) : 0);
        out[name] = std::move(buf);
    }
    pa_pbo_close(pbo);
    return out;
}

// Compare two readers' entry maps; returns the number of mismatches (0 == parity).
static int diff(const std::string& pbo, const EntryMap& c, const EntryMap& r) {
    int mismatches = 0;
    if (c.size() != r.size()) {
        std::fprintf(stderr, "  entry count differs: C++=%zu Rust=%zu\n", c.size(), r.size());
        ++mismatches;
    }
    for (const auto& [name, cbytes] : c) {
        auto it = r.find(name);
        if (it == r.end()) {
            std::fprintf(stderr, "  '%s' present in C++ but missing in Rust\n", name.c_str());
            ++mismatches;
            continue;
        }
        if (cbytes != it->second) {
            std::fprintf(stderr, "  '%s' content differs (C++=%zu B, Rust=%zu B)\n",
                         name.c_str(), cbytes.size(), it->second.size());
            ++mismatches;
        }
    }
    for (const auto& [name, _] : r) {
        if (!c.count(name)) {
            std::fprintf(stderr, "  '%s' present in Rust but missing in C++\n", name.c_str());
            ++mismatches;
        }
    }
    if (mismatches == 0) {
        std::printf("  OK  %-48s %zu entries identical\n",
                    fs::path(pbo).filename().string().c_str(), c.size());
    }
    return mismatches;
}

static void collect(const char* dir, std::vector<std::string>& out) {
    if (!dir || !fs::exists(dir)) return;
    for (const auto& e : fs::recursive_directory_iterator(dir)) {
        if (e.is_regular_file() && e.path().extension() == ".pbo") {
            out.push_back(e.path().string());
        }
    }
}

int main() {
    if (!pf_init()) {
        std::fprintf(stderr, "pf_init() failed\n");
        return 1;
    }

    std::vector<std::string> pbos;
    collect(FIXTURES_DIR, pbos);
    if (const char* extra = std::getenv("POSEIDON_PBO_PARITY_DIR")) {
        const size_t before = pbos.size();
        collect(extra, pbos);
        std::printf("Scanning external PBO dir %s (+%zu archives)\n", extra, pbos.size() - before);
    }
    if (pbos.empty()) {
        std::fprintf(stderr, "no .pbo fixtures found under %s\n", FIXTURES_DIR);
        return 1;
    }

    int failures = 0;
    for (const auto& pbo : pbos) {
        int err = 0;
        EntryMap c = readWithCpp(pbo, err);
        EntryMap r = readWithRust(pbo, err);
        if (err) {
            std::fprintf(stderr, "  open error on %s\n", pbo.c_str());
            ++failures;
            continue;
        }
        failures += diff(pbo, c, r);
    }

    pf_shutdown();
    if (failures == 0) {
        std::printf("PBO parity: C++ and Rust readers agree on %zu archives\n", pbos.size());
    }
    return failures == 0 ? 0 : 1;
}
