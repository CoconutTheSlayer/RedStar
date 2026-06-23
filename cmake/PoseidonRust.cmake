# PoseidonRust — imports the Rust staticlib spike into the CMake build via
# Corrosion (https://github.com/corrosion-rs/corrosion), the standard
# CMake<->Cargo bridge. Corrosion drives `cargo` as part of the normal build,
# tracks the crate's sources for incremental rebuilds, and produces an imported
# target named after the crate lib (`poseidon_rust`).
#
# Included from the root CMakeLists only when POSEIDON_ENABLE_RUST is ON.

include(FetchContent)

# Pinned tag; first configure fetches it (network required once, then cached).
FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG        v0.5.1
)
FetchContent_MakeAvailable(Corrosion)

corrosion_import_crate(
    MANIFEST_PATH ${CMAKE_CURRENT_LIST_DIR}/../engine/PoseidonRust/Cargo.toml
    CRATE_TYPES   staticlib
)

# Attach the hand-written C header to the imported target, then expose it under a
# stable alias so consumers depend on `PoseidonRust`, not Corrosion's crate name.
target_include_directories(poseidon_rust INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}/../engine/PoseidonRust/include
)
add_library(PoseidonRust ALIAS poseidon_rust)
