# Full subtitle decoders, LGPL build; pin both architectures and verify SHA-256.
# Corresponding build sources and notices: third_party/libmpv/NOTICE.md.
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(mpv_arch "aarch64")
  set(mpv_hash "d567591f7a5afb735f4d6817c3b3eda96af8d1e342f856345fef040dc333c820")
else()
  set(mpv_arch "x86_64")
  set(mpv_hash "6429ebba4b6bfc5dd18ac5ac084f00776db0db4e767ef1bfb815fc78ec5bda2a")
endif()
set(mpv_name "mpv-dev-lgpl-${mpv_arch}-20261025-git-baa3e11d42.7z")
set(mpv_archive "${CMAKE_BINARY_DIR}/${mpv_name}")
# media_kit_video's renderer links headers/import libraries from this directory.
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")
if(EXISTS "${mpv_archive}")
  file(SHA256 "${mpv_archive}" actual)
endif()
if(NOT actual STREQUAL mpv_hash)
  file(DOWNLOAD
    "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-10-25-baa3e11d42/${mpv_name}"
    "${mpv_archive}" EXPECTED_HASH "SHA256=${mpv_hash}" TLS_VERIFY ON)
endif()
set(installed_hash "")
set(mpv_install_id "${mpv_hash}-7zip25.01")
if(EXISTS "${LIBMPV_SRC}/.oplayer-sha256")
  file(READ "${LIBMPV_SRC}/.oplayer-sha256" installed_hash)
endif()
if(NOT installed_hash STREQUAL mpv_install_id OR NOT EXISTS "${LIBMPV_SRC}/include/client.h")
  # libarchive in some CMake versions cannot decode the ARM64 BCJ filter.
  # Use pinned official 7-Zip, which also checks archive CRCs before continuing.
  set(seven_zip "${CMAKE_BINARY_DIR}/7zr-25.01.exe")
  set(seven_zip_hash "27cbe3d5804ad09e90bbcaa916da0d5c3b0be9462d0e0fb6cb54be5ed9030875")
  set(actual_seven_zip_hash "")
  if(EXISTS "${seven_zip}")
    file(SHA256 "${seven_zip}" actual_seven_zip_hash)
  endif()
  if(NOT actual_seven_zip_hash STREQUAL seven_zip_hash)
    file(DOWNLOAD "https://github.com/ip7z/7zip/releases/download/25.01/7zr.exe"
      "${seven_zip}" EXPECTED_HASH "SHA256=${seven_zip_hash}" TLS_VERIFY ON)
  endif()
  execute_process(COMMAND "${seven_zip}" x -y "-o${LIBMPV_SRC}" "${mpv_archive}"
    OUTPUT_QUIET COMMAND_ERROR_IS_FATAL ANY)
  file(COPY "${LIBMPV_SRC}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include")
  if(NOT EXISTS "${LIBMPV_SRC}/include/client.h" OR NOT EXISTS "${LIBMPV_SRC}/libmpv.dll.a"
      OR NOT EXISTS "${LIBMPV_SRC}/libmpv-2.dll")
    message(FATAL_ERROR "The verified libmpv archive is incomplete")
  endif()
  file(WRITE "${LIBMPV_SRC}/.oplayer-sha256" "${mpv_install_id}")
endif()
