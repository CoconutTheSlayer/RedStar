# PBO reader parity test: the C++ (PoseidonFormats) and Rust (PoseidonArchive)
# readers must agree byte-for-byte on every archive. Links both readers;
# PoseidonFormats pulls in the engine (Poseidon).
add_executable(test_pbo_parity test_pbo_parity.cpp)
target_link_libraries(test_pbo_parity PRIVATE PoseidonArchive PoseidonFormats)
target_compile_features(test_pbo_parity PRIVATE cxx_std_20)
target_compile_definitions(test_pbo_parity PRIVATE
    FIXTURES_DIR="${CMAKE_SOURCE_DIR}/tests/fixtures")

add_test(NAME PoseidonArchive.PboParity COMMAND test_pbo_parity)
