# RustSpike — proves the C++ -> Rust (Corrosion/Cargo) toolchain seam end to end.
# Links the imported Rust staticlib (PoseidonRust) and runs as the RustSpike test.
add_executable(RustSpike main.cpp)
target_link_libraries(RustSpike PRIVATE PoseidonRust)
target_compile_features(RustSpike PRIVATE cxx_std_20)

add_test(NAME RustSpike COMMAND RustSpike)
