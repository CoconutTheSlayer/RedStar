# PBO reader parity test: the C++ and Rust (PoseidonArchive) readers must agree
# byte-for-byte on every archive. Links the Rust reader plus PoseidonFormatsRef —
# the reference build pinned to the C++ QFBank path — so the comparison stays
# meaningful regardless of POSEIDON_PBO_USE_RUST's default. (PoseidonFormatsRef
# pulls in the engine, Poseidon.)
add_executable(test_pbo_parity test_pbo_parity.cpp)
target_link_libraries(test_pbo_parity PRIVATE PoseidonArchive PoseidonFormatsRef)
target_compile_features(test_pbo_parity PRIVATE cxx_std_20)
target_compile_definitions(test_pbo_parity PRIVATE
    FIXTURES_DIR="${CMAKE_SOURCE_DIR}/tests/fixtures")

add_test(NAME PoseidonArchive.PboParity COMMAND test_pbo_parity)
