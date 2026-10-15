cmake_minimum_required(VERSION 3.22.1)
project("smolchat_native" LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# SmolChat architecture: native C++ LLMInference -> llama.cpp -> GGUF.
# This Android target is intentionally 32-bit ARM only.
if (ANDROID AND NOT ANDROID_ABI STREQUAL "armeabi-v7a")
  message(FATAL_ERROR "Portable AI native engine must be built for armeabi-v7a; got ${ANDROID_ABI}")
endif()

# Use a shared lib build (we produce a shared .so)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

# Portable ARMv7/32-bit Android flags used by the SmolChat ARMv7 build approach.
# We enable NEON + hard-float where appropriate and tune compiler optimizations
if (ANDROID_ABI STREQUAL "armeabi-v7a")
  # Use ARMv7-A with NEON for better performance on supported devices.
  # Use hard float ABI where supported by the NDK and device for maximum performance.
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=armv7-a -mfpu=neon -mfloat-abi=hard -O3 -ffast-math -funroll-loops -fvisibility=hidden")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv7-a -mfpu=neon -mfloat-abi=hard -O3 -ffast-math -funroll-loops -fvisibility=hidden")
endif()

include(FetchContent)
FetchContent_Declare(
  llama_cpp
  URL https://github.com/ggml-org/llama.cpp/archive/465e49b9cea78a68b9c244ffb48d0ee24a82873d.tar.gz
)
FetchContent_MakeAvailable(llama_cpp)

add_library(smolchat_native SHARED
  smolchat_jni.cpp
  LLMInference.cpp
)

target_include_directories(smolchat_native PRIVATE
  ${llama_cpp_SOURCE_DIR}/include
  ${llama_cpp_SOURCE_DIR}/common
  ${llama_cpp_SOURCE_DIR}/ggml/include
  ${llama_cpp_SOURCE_DIR}/ggml/src
  ${llama_cpp_SOURCE_DIR}/vendor
)

# Additional compile options tuned for armv7a + NEON
target_compile_options(smolchat_native PRIVATE
  -march=armv7-a
  -mfpu=neon
  -mfloat-abi=hard
  -O3
  -fvisibility=hidden
  -fvisibility-inlines-hidden
  -ffunction-sections
  -fdata-sections
  -ffast-math
  -funroll-loops
)

# Enable GGML/llama optimizations where available. These macros are respected by
# the pinned llama.cpp source. Enabling NEON provides improved performance on
# ARM devices with NEON support (most modern ARMv7 devices).
# Keep OpenMP disabled because Android NDK/OpenMP can be problematic on some devices.
target_compile_definitions(smolchat_native PRIVATE GGML_USE_CPU=1 GGML_USE_NEON=1 GGML_USE_ACCELERATE=0)

# Link against the llama common & llama targets provided by the fetched llama.cpp
# This mirrors the original build but with NEON acceleration enabled.
target_link_libraries(smolchat_native PRIVATE android log llama-common llama)
target_link_options(smolchat_native PRIVATE
  -Wl,--gc-sections
  -Wl,--exclude-libs,ALL
)
