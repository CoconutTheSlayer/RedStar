# PoseidonArchive — imports the poseidon_archive Rust staticlib (PBO reading,
# backed by the standalone papa-bear-archive crate) into the CMake build.
#
# Relies on Corrosion already being available: cmake/PoseidonRust.cmake fetches it
# and must be included before this file (the root CMakeLists does so).

corrosion_import_crate(
    MANIFEST_PATH ${CMAKE_CURRENT_LIST_DIR}/../engine/PoseidonArchive/Cargo.toml
    CRATE_TYPES   staticlib
)

target_include_directories(poseidon_archive INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}/../engine/PoseidonArchive/include
)
add_library(PoseidonArchive ALIAS poseidon_archive)
