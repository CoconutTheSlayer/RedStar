# PoseidonFormats - Unified format reading library
# Shared C API for P3D models, PAA textures, PBO archives
# Static: TC plugins, Tools, Studio | Dynamic (DLL): Blender addon

cmake_minimum_required(VERSION 3.25)

set(PF_SOURCES PoseidonFormats.cpp)

# Static library (for TC plugins, Tools, Studio)
add_library(PoseidonFormats STATIC ${PF_SOURCES})
target_include_directories(PoseidonFormats PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(PoseidonFormats PUBLIC Poseidon)
target_compile_features(PoseidonFormats PRIVATE cxx_std_20)

# Optionally back the PBO reader (pf_pbo_*) with the Rust PoseidonArchive crate.
if(POSEIDON_PBO_USE_RUST)
    target_link_libraries(PoseidonFormats PRIVATE PoseidonArchive)
    target_compile_definitions(PoseidonFormats PRIVATE POSEIDON_PBO_USE_RUST=1)
endif()

# Shared library / DLL (for Blender addon, x64 only)
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    add_library(PoseidonFormatsDLL SHARED ${PF_SOURCES})
    target_include_directories(PoseidonFormatsDLL PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_definitions(PoseidonFormatsDLL PRIVATE PF_BUILDING_DLL=1)
    target_compile_features(PoseidonFormatsDLL PRIVATE cxx_std_20)
    if(WIN32)
        target_link_libraries(PoseidonFormatsDLL PRIVATE Poseidon winmm)
    elseif(APPLE)
        # ld64 (Mach-O) has no --start-group/--end-group (unneeded; the linker
        # resolves archives without ordering constraints) and no -Bsymbolic.
        # Two-level namespaces already bind our own symbols internally.
        set_target_properties(PoseidonFormatsDLL PROPERTIES
            POSITION_INDEPENDENT_CODE ON
        )
        target_link_libraries(PoseidonFormatsDLL PRIVATE Poseidon)
    else()
        # On Linux, statically linked dependencies need PIC. Use -Bsymbolic
        # and link only what's needed from the engine libraries.
        set_target_properties(PoseidonFormatsDLL PROPERTIES
            POSITION_INDEPENDENT_CODE ON
        )
        target_link_libraries(PoseidonFormatsDLL PRIVATE
            -Wl,--start-group Poseidon -Wl,--end-group
        )
        target_link_options(PoseidonFormatsDLL PRIVATE -Wl,-Bsymbolic)
    endif()
    set_target_properties(PoseidonFormatsDLL PROPERTIES
        OUTPUT_NAME "PoseidonFormats"
        PREFIX ""
        ARCHIVE_OUTPUT_NAME "PoseidonFormats_dll"
    )
    # Copy DLL to dist
    include(${CMAKE_SOURCE_DIR}/cmake/DistCopy.cmake)
    dist_copy(PoseidonFormatsDLL)
endif()
