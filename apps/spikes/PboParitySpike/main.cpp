// PboParitySpike — differential parity test between the C++ PBO reader
// (PoseidonFormats' pf_pbo_* over QFBank) and the Rust reader (PoseidonArchive's
// pa_pbo_* over papa-bear-archive). For every .pbo fixture it asserts both
// readers expose the same set of entries and byte-for-byte identical decompressed
// contents. This is the gate before routing any engine call site through Rust.
//
// FIXTURES_DIR (a directory searched recursively for *.pbo) is injected by CMake.
#include "PoseidonFormats.h"
#include "poseidon_archive.h"

#include <cctype>
#include <cstdio>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
using EntryMap = std::map<std::string, Bytes>;

// OFP paths are case-insensitive and use backslashes internally; normalise so the
// two readers' naming conventions don't cause spurious mismatches. Content bytes
// are always compared raw.
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

// Compare two readers' entry maps; returns number of mismatches (0 == parity).
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

int main() {
    if (!pf_init()) {
        std::fprintf(stderr, "pf_init() failed\n");
        return 1;
    }

    std::vector<std::string> pbos;
    for (const auto& e : fs::recursive_directory_iterator(FIXTURES_DIR)) {
        if (e.is_regular_file() && e.path().extension() == ".pbo") {
            pbos.push_back(e.path().string());
        }
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
        std::printf("PboParitySpike: C++ and Rust PBO readers agree on %zu archives\n", pbos.size());
    }
    return failures == 0 ? 0 : 1;
}
