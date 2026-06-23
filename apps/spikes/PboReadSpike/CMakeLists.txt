# PboReadSpike — proves the first real Rust module (PBO reading) end to end:
# links the imported poseidon_archive staticlib and reads a real PBO fixture.
add_executable(PboReadSpike main.cpp)
target_link_libraries(PboReadSpike PRIVATE PoseidonArchive)
target_compile_features(PboReadSpike PRIVATE cxx_std_20)
target_compile_definitions(PboReadSpike PRIVATE
    FIXTURE_PBO="${CMAKE_SOURCE_DIR}/tests/fixtures/pbo/addon_fixture.pbo")

add_test(NAME PboReadSpike COMMAND PboReadSpike)
