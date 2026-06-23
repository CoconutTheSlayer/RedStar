# DistCopy.cmake — Helper to copy build artifacts to dist/<preset>/
#
# Usage:
#   include(${CMAKE_SOURCE_DIR}/cmake/DistCopy.cmake)
#   dist_copy(PoseidonGame)                              # copy binary + PDB
#   dist_copy(TcPbo RENAME pbo${WCX_SUFFIX})             # copy with rename
#   dist_copy(TcPbo EXTRA pluginst.inf)                  # copy extra file from source dir

function(dist_copy TARGET)
    cmake_parse_arguments(ARG "" "RENAME" "EXTRA" ${ARGN})

    if(ARG_RENAME)
        set(_dst "${DIST_DIR}/${ARG_RENAME}")
    else()
        set(_dst "${DIST_DIR}/$<TARGET_FILE_NAME:${TARGET}>")
    endif()

    add_custom_command(TARGET ${TARGET} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory ${DIST_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:${TARGET}> ${_dst}
        COMMENT "Copying ${TARGET} to ${DIST_DIR}"
        VERBATIM
    )

    # Copy PDB on Windows debug builds
    if(WIN32 AND NOT CMAKE_BUILD_TYPE STREQUAL "Release")
        get_target_property(_type ${TARGET} TYPE)
        if(_type STREQUAL "EXECUTABLE" OR _type STREQUAL "SHARED_LIBRARY")
            add_custom_command(TARGET ${TARGET} POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    $<TARGET_PDB_FILE:${TARGET}> ${DIST_DIR}/
                VERBATIM
            )
        endif()
    endif()

    # Copy runtime DLLs (e.g., OpenAL32.dll — LGPL dynamic linkage)
    if(WIN32 AND TARGET OpenAL::OpenAL)
        get_target_property(_openal_dll OpenAL::OpenAL IMPORTED_LOCATION)
        if(NOT _openal_dll)
            get_target_property(_openal_dll OpenAL::OpenAL IMPORTED_LOCATION_RELEASE)
        endif()
        if(_openal_dll AND _openal_dll MATCHES "\\.dll$")
            add_custom_command(TARGET ${TARGET} POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${_openal_dll}" "${DIST_DIR}"
                VERBATIM
            )
        endif()
        unset(_openal_dll)
    endif()

    # macOS: OpenAL is a .dylib (LGPL dynamic linkage). The engine dlopen()s it
    # via @loader_path, so it must sit next to the executable — both in the dist
    # dir and beside the freshly-built binary in the build tree. The runtime
    # SONAME is libopenal.1.dylib (the symlink target vcpkg installs).
    if(APPLE)
        get_target_property(_type ${TARGET} TYPE)
        if(_type STREQUAL "EXECUTABLE")
            set(_openal_dylib
                "${CMAKE_BINARY_DIR}/vcpkg_installed/${VCPKG_TARGET_TRIPLET}/lib/libopenal.1.dylib")
            if(EXISTS "${_openal_dylib}")
                add_custom_command(TARGET ${TARGET} POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        "${_openal_dylib}" "$<TARGET_FILE_DIR:${TARGET}>"
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        "${_openal_dylib}" "${DIST_DIR}"
                    COMMENT "Copying libopenal.1.dylib next to ${TARGET}"
                    VERBATIM
                )
            endif()
            unset(_openal_dylib)
        endif()
    endif()

    # Copy extra files from the target's source directory
    foreach(_extra ${ARG_EXTRA})
        get_filename_component(_name "${_extra}" NAME)
        add_custom_command(TARGET ${TARGET} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${CMAKE_CURRENT_SOURCE_DIR}/${_extra} ${DIST_DIR}/${_name}
            VERBATIM
        )
    endforeach()
endfunction()
