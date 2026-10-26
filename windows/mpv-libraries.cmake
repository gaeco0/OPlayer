# Full subtitle decoders, LGPL build; pin both architectures and verify SHA-256.
# Corresponding build sources and notices: third_party/libmpv/README.md.
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(mpv_arch "aarch64")
  set(mpv_hash "d567591f7a5afb735f4d6817c3b3eda96af8d1e342f856345fef040dc333c820")
else()
  set(mpv_arch "x86_64")
  set(mpv_hash "6429ebba4b6bfc5dd18ac5ac084f00776db0db4e767ef1bfb815fc78ec5bda2a")
endif()
set(mpv_name "mpv-dev-lgpl-${mpv_arch}-20261025-git-baa3e11d42.7z")
set(mpv_archive "${CMAKE_BINARY_DIR}/${mpv_name}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv-lgpl-baa3e11d42-${mpv_arch}")
if(EXISTS "${mpv_archive}")
  file(SHA256 "${mpv_archive}" actual)
endif()
if(NOT actual STREQUAL mpv_hash)
  file(DOWNLOAD
    "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-10-25-baa3e11d42/${mpv_name}"
    "${mpv_archive}" EXPECTED_HASH "SHA256=${mpv_hash}" TLS_VERIFY ON)
endif()
if(NOT EXISTS "${LIBMPV_SRC}/libmpv-2.dll")
  file(ARCHIVE_EXTRACT INPUT "${mpv_archive}" DESTINATION "${LIBMPV_SRC}")
  file(COPY "${LIBMPV_SRC}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include")
endif()
