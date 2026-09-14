cmake_minimum_required(VERSION 3.14)
project(wamr_repl C)

include(FetchContent)

if(NOT WAMR_ROOT_DIR)
  FetchContent_Declare(
    wamr
    GIT_REPOSITORY https://github.com/bytecodealliance/wasm-micro-runtime.git
    GIT_TAG WAMR-2.4.5
    GIT_SHALLOW TRUE
  )
  FetchContent_GetProperties(wamr)
  if(NOT wamr_POPULATED)
    FetchContent_Populate(wamr)
  endif()
  set(WAMR_ROOT_DIR "${wamr_SOURCE_DIR}")
endif()

string(TOLOWER "${CMAKE_HOST_SYSTEM_NAME}" WAMR_BUILD_PLATFORM)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)")
  set(WAMR_BUILD_TARGET AARCH64)
elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "riscv64")
  set(WAMR_BUILD_TARGET RISCV64)
elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(WAMR_BUILD_TARGET X86_64)
else()
  set(WAMR_BUILD_TARGET X86_32)
endif()
set(WAMR_BUILD_INTERP 1)
set(WAMR_BUILD_FAST_INTERP 1)
set(WAMR_BUILD_AOT 0)
set(WAMR_BUILD_JIT 0)
set(WAMR_BUILD_LIBC_BUILTIN 0)
set(WAMR_BUILD_LIBC_WASI 0)
set(WAMR_BUILD_MULTI_MODULE 1)
set(WAMR_BUILD_REF_TYPES 1)

include("${WAMR_ROOT_DIR}/build-scripts/runtime_lib.cmake")
add_library(vmlib STATIC ${WAMR_RUNTIME_LIB_SOURCE})

add_executable(wamr-repl main.c)
target_include_directories(wamr-repl PRIVATE "${WAMR_ROOT_DIR}/core/iwasm/include")
target_link_libraries(wamr-repl PRIVATE vmlib m pthread dl)
target_compile_options(wamr-repl PRIVATE -Wall -Wextra)
