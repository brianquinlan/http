# Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Builds the static libraries that libcurl depends on, BoringSSL (libcrypto and
# libssl) and nghttp2, from the sources in `third_party/` and installs them,
# with their headers, into CMAKE_INSTALL_PREFIX.
#
# Invoked by `hook/build.dart`. The libraries are built separately from libcurl
# because libcurl's CMake build compiles and links test programs against its
# dependencies to detect their features, so they must already be built when
# libcurl is configured.

# 3.16 for list(TRANSFORM) and target_precompile_headers era features.
cmake_minimum_required(VERSION 3.16)
project(curl_http_deps LANGUAGES C CXX)

set(THIRD_PARTY "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party")

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# The libraries are linked into a shared library.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# Only the symbols of `src/curl_http.c` are exported from the shared library.
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

include(GNUInstallDirs)

#
# BoringSSL
#

set(BORINGSSL_ROOT "${THIRD_PARTY}/boringssl")
include("${BORINGSSL_ROOT}/gen/sources.cmake")

foreach(var BCM_SOURCES BCM_SOURCES_ASM CRYPTO_SOURCES CRYPTO_SOURCES_ASM
            SSL_SOURCES)
  list(TRANSFORM ${var} PREPEND "${BORINGSSL_ROOT}/")
endforeach()

if(WIN32)
  # BoringSSL's x86 assembly for Windows requires NASM, so use the C
  # implementations instead.
  set(BORINGSSL_ASM_SOURCES)
  set(BORINGSSL_DEFINITIONS OPENSSL_NO_ASM)
else()
  # Each assembly file is guarded by preprocessor checks for the architecture
  # and operating system that it is written for, so all of them can be compiled
  # for every target.
  enable_language(ASM)
  set(BORINGSSL_ASM_SOURCES ${BCM_SOURCES_ASM} ${CRYPTO_SOURCES_ASM})
  set(BORINGSSL_DEFINITIONS)
endif()

list(APPEND BORINGSSL_DEFINITIONS
  BORINGSSL_IMPLEMENTATION
  # Keep BoringSSL free of C++ runtime symbols (such as operator delete from
  # virtual destructors), so that the C compiler driver can link it.
  BORINGSSL_TEMPORARY_NO_CXX_RUNTIME
)
if(WIN32)
  list(APPEND BORINGSSL_DEFINITIONS
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS _HAS_EXCEPTIONS=0)
endif()

if(MSVC)
  set(BORINGSSL_OPTIONS -utf-8)
else()
  set(BORINGSSL_OPTIONS -fno-strict-aliasing -fno-common
    $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions -fno-rtti>
    # With exceptions disabled, libc++ calls std::__libcpp_verbose_abort, which
    # is defined in the libc++ runtime library. Abort directly instead.
    "$<$<COMPILE_LANGUAGE:CXX>:-D_LIBCPP_VERBOSE_ABORT(...)=__builtin_abort()>")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # pthread_rwlock_t on Linux requires a feature flag.
    list(APPEND BORINGSSL_OPTIONS $<$<COMPILE_LANGUAGE:C>:-D_XOPEN_SOURCE=700>)
  endif()
  if(CMAKE_ASM_COMPILER_ID MATCHES "Clang" OR CMAKE_C_COMPILER_ID MATCHES "Clang")
    # Some assembly files are empty for the target architecture.
    list(APPEND BORINGSSL_OPTIONS $<$<COMPILE_LANGUAGE:ASM>:-Wno-unused-command-line-argument>)
  endif()
endif()

add_library(crypto STATIC
  ${BCM_SOURCES} ${CRYPTO_SOURCES} ${BORINGSSL_ASM_SOURCES})
target_include_directories(crypto PUBLIC "${BORINGSSL_ROOT}/include")
target_compile_definitions(crypto PRIVATE ${BORINGSSL_DEFINITIONS})
target_compile_options(crypto PRIVATE ${BORINGSSL_OPTIONS})

add_library(ssl STATIC ${SSL_SOURCES})
target_link_libraries(ssl PUBLIC crypto)
target_compile_definitions(ssl PRIVATE ${BORINGSSL_DEFINITIONS})
target_compile_options(ssl PRIVATE ${BORINGSSL_OPTIONS})

install(TARGETS crypto ssl ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
install(DIRECTORY "${BORINGSSL_ROOT}/include/openssl"
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")

#
# nghttp2
#

set(NGHTTP2_ROOT "${THIRD_PARTY}/nghttp2")
file(GLOB NGHTTP2_SOURCES "${NGHTTP2_ROOT}/lib/*.c")
file(STRINGS "${NGHTTP2_ROOT}/VENDORED.md" NGHTTP2_TITLE LIMIT_COUNT 1
  REGEX "^# nghttp2 ")
string(REGEX REPLACE "^# nghttp2 " "" PACKAGE_VERSION "${NGHTTP2_TITLE}")
string(REGEX MATCHALL "[0-9]+" NGHTTP2_VERSION_PARTS "${PACKAGE_VERSION}")
list(GET NGHTTP2_VERSION_PARTS 0 NGHTTP2_MAJOR)
list(GET NGHTTP2_VERSION_PARTS 1 NGHTTP2_MINOR)
list(GET NGHTTP2_VERSION_PARTS 2 NGHTTP2_PATCH)
math(EXPR PACKAGE_VERSION_NUM
  "(${NGHTTP2_MAJOR} << 16) + (${NGHTTP2_MINOR} << 8) + ${NGHTTP2_PATCH}"
  OUTPUT_FORMAT HEXADECIMAL)
set(NGHTTP2_GENERATED_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/nghttp2/include")
configure_file("${NGHTTP2_ROOT}/lib/includes/nghttp2/nghttp2ver.h.in"
  "${NGHTTP2_GENERATED_INCLUDE}/nghttp2/nghttp2ver.h" @ONLY)

add_library(nghttp2 STATIC ${NGHTTP2_SOURCES})
target_include_directories(nghttp2
  PUBLIC "${NGHTTP2_ROOT}/lib/includes" "${NGHTTP2_GENERATED_INCLUDE}")
target_compile_definitions(nghttp2
  PUBLIC NGHTTP2_STATICLIB
  PRIVATE BUILDING_NGHTTP2)
if(WIN32)
  target_compile_definitions(nghttp2 PRIVATE HAVE_WINDOWS_H HAVE_GETTICKCOUNT64)
  target_link_libraries(nghttp2 PUBLIC ws2_32)
else()
  target_compile_definitions(nghttp2 PRIVATE
    HAVE_ARPA_INET_H HAVE_NETINET_IN_H HAVE_CLOCK_GETTIME
    HAVE_DECL_CLOCK_MONOTONIC=1)
endif()

install(TARGETS nghttp2 ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
install(FILES
  "${NGHTTP2_ROOT}/lib/includes/nghttp2/nghttp2.h"
  "${NGHTTP2_GENERATED_INCLUDE}/nghttp2/nghttp2ver.h"
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/nghttp2")
