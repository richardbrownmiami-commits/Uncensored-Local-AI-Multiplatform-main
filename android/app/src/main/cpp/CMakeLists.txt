cmake_minimum_required(VERSION 3.22.1)
project("smolchat_native" LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# SmolChat architecture: native C++ LLMInference -> llama.cpp -> GGUF.
# This Android target is intentionally 32-bit ARM only.
if (ANDROID AND NOT ANDROID_ABI STREQUAL "armeabi-v7a")
  message(FATAL_ERROR "Portable AI native engine must be built for armeabi-v7a; got ${ANDROID_ABI}")
endif()

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

# ARMv7/32-bit Android settings used by SmolChat's ARMv7 build discussion.
# Apply them before FetchContent so llama.cpp itself receives the same target flags.
if (ANDROID_ABI STREQUAL "armeabi-v7a")
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp" CACHE STRING "" FORCE)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp" CACHE STRING "" FORCE)
  set(ANDROID_ARM_NEON ON CACHE BOOL "" FORCE)
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

if (ANDROID_ABI STREQUAL "armeabi-v7a")
  target_compile_options(smolchat_native PRIVATE
    -march=armv7-a
    -mfpu=vfpv3-d16
    -mfloat-abi=softfp
    -O3
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -ffunction-sections
    -fdata-sections
  )
endif()

target_compile_definitions(smolchat_native PRIVATE GGML_USE_CPU=1)

target_link_libraries(smolchat_native PRIVATE android log llama common)
target_link_options(smolchat_native PRIVATE
  -Wl,--gc-sections
  -Wl,--exclude-libs,ALL
)
