# PoseidonMetal — native Metal rendering backend (Apple Silicon / macOS only).
# Built only when APPLE; mirrors PoseidonGL33 as a parallel STATIC backend lib.

enable_language(OBJCXX)

set(POSEIDON_METAL_SOURCES
    GraphicsBackendMetal.cpp   # pure C++ registration
    EngineMetal.mm             # Objective-C++ engine (window/clear/present/screenshot)
)

set(POSEIDON_METAL_HEADERS
    ${CMAKE_CURRENT_SOURCE_DIR}/EngineMetal.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/EngineFactoryMetal.hpp
)

add_library(PoseidonMetal STATIC
    ${POSEIDON_METAL_SOURCES}
    ${POSEIDON_METAL_HEADERS}
)

target_link_libraries(PoseidonMetal PUBLIC Poseidon)
target_include_directories(PoseidonMetal PUBLIC ${CMAKE_SOURCE_DIR}/engine)

# Apple frameworks for Metal + the CAMetalLayer swapchain.
target_link_libraries(PoseidonMetal PUBLIC
    "-framework Metal"
    "-framework QuartzCore"
    "-framework Foundation"
)

# ARC for the Objective-C++ TUs (auto-manages id<MTL...> lifetimes).
set_source_files_properties(EngineMetal.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

# --- Compile MSL shaders into a metallib at build time ---
set(METAL_SHADER ${CMAKE_CURRENT_SOURCE_DIR}/Shaders/Shaders.metal)
set(METAL_AIR ${CMAKE_CURRENT_BINARY_DIR}/Shaders.air)
set(METAL_LIB ${CMAKE_BINARY_DIR}/Poseidon.metallib)
add_custom_command(
    OUTPUT ${METAL_LIB}
    COMMAND xcrun -sdk macosx metal -gline-tables-only -frecord-sources -c ${METAL_SHADER} -o ${METAL_AIR}
    COMMAND xcrun -sdk macosx metallib ${METAL_AIR} -o ${METAL_LIB}
    DEPENDS ${METAL_SHADER}
    COMMENT "Compiling MSL shaders -> Poseidon.metallib"
    VERBATIM
)
add_custom_target(PoseidonMetallib DEPENDS ${METAL_LIB})
add_dependencies(PoseidonMetal PoseidonMetallib)

target_compile_definitions(PoseidonMetal PRIVATE
    $<$<CONFIG:Debug>:_DEBUG>
    POSEIDON_METALLIB_PATH="${METAL_LIB}"
)

target_compile_options(PoseidonMetal PRIVATE
    -Wno-error
    -Wno-deprecated-volatile
    -Wno-missing-field-initializers
)

set_target_properties(PoseidonMetal PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OUTPUT_NAME "PoseidonMetal"
)
