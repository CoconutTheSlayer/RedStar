# PboParitySpike — differential test: the C++ (PoseidonFormats) and Rust
# (PoseidonArchive) PBO readers must agree byte-for-byte on every fixture.
# Links both readers; PoseidonFormats pulls in the engine (Poseidon).
add_executable(PboParitySpike main.cpp)
target_link_libraries(PboParitySpike PRIVATE PoseidonArchive PoseidonFormats)
target_compile_features(PboParitySpike PRIVATE cxx_std_20)
target_compile_definitions(PboParitySpike PRIVATE
    FIXTURES_DIR="${CMAKE_SOURCE_DIR}/tests/fixtures")

add_test(NAME PboParitySpike COMMAND PboParitySpike)
