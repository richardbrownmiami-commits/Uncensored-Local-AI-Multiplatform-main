cmake_minimum_required(VERSION 3.22.1)
project("smolchat_native" LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# SmolChat architecture: native C++ LLMInference -> llama.cpp -> GGUF.
# Keep Android CPU-only and build the same ARMv7 target used by SmolChat.
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
    -mfpu=neon-vfpv4
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
