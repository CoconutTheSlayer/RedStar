# macOS arm64 (Apple Silicon) — Apple Clang + libc++ + ld64.
# Mirrors linux-x64-clang.cmake but without the x86 -m64 flag and ELF-isms.
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)

# Native build - prevent CMake from treating this as cross-compilation
set(CMAKE_CROSSCOMPILING FALSE)

# Apple Silicon, single-arch. Keep this in sync with the arm64-osx-clang triplet.
set(CMAKE_OSX_ARCHITECTURES "arm64")

# Minimum macOS we build against. 12.0 (Monterey) gives us a stable libc++ and
# the OpenGL 4.1 framework the GL33 backend needs. Bump if you require newer APIs.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
endif()
