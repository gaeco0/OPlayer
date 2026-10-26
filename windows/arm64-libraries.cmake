# Architecture-specific binaries for media_kit's Windows ARM64 renderer.
# Sources and licenses: third_party/angle-arm64 and third_party/libmpv.
function(oplayer_verified_download url hash destination)
  if(EXISTS "${destination}")
    file(SHA256 "${destination}" actual)
    if(actual STREQUAL hash)
      return()
    endif()
  endif()
  file(DOWNLOAD "${url}" "${destination}" EXPECTED_HASH "SHA256=${hash}" TLS_VERIFY ON)
endfunction()

include("${CMAKE_SOURCE_DIR}/mpv-libraries.cmake")

# Reuse architecture-independent EGL/GLES headers from the existing package.
set(header_archive "${CMAKE_BINARY_DIR}/ANGLE.7z")
download_and_verify(
  "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
  "e866f13e8d552348058afaafe869b1ed" "${header_archive}")
set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")
file(ARCHIVE_EXTRACT INPUT "${header_archive}" DESTINATION "${ANGLE_SRC}")
set(angle_archive "${CMAKE_BINARY_DIR}/angle-arm64.nupkg")
oplayer_verified_download(
  "https://api.nuget.org/v3-flatcontainer/avalonia.angle.windows.natives/2.1.27548.20260419/avalonia.angle.windows.natives.2.1.27548.20260419.nupkg"
  "76d67901097e9173d155efc4c2b7d2c8e3122f2c2e0415028eb0c88478a386f9" "${angle_archive}")
file(ARCHIVE_EXTRACT INPUT "${angle_archive}" DESTINATION "${CMAKE_BINARY_DIR}/angle-arm64")
file(COPY "${CMAKE_BINARY_DIR}/angle-arm64/runtimes/win-arm64/native/av_libglesv2.dll" DESTINATION "${ANGLE_SRC}")

# Avalonia's ANGLE combines EGL/GLES in one DLL and exports EGL_* names.
# Generate an ARM64 import library and compile-time aliases for the EGL API.
get_filename_component(msvc_bin "${CMAKE_LINKER}" DIRECTORY)
execute_process(COMMAND "${msvc_bin}/dumpbin.exe" /exports "${ANGLE_SRC}/av_libglesv2.dll"
  OUTPUT_FILE "${ANGLE_SRC}/exports.txt" COMMAND_ERROR_IS_FATAL ANY)
file(STRINGS "${ANGLE_SRC}/exports.txt" export_lines)
set(exports "LIBRARY av_libglesv2.dll\nEXPORTS\n")
set(egl_aliases "")
foreach(line IN LISTS export_lines)
  if(line MATCHES "^[ ]+[0-9]+[ ]+[0-9A-Fa-f]+[ ]+[0-9A-Fa-f]+[ ]+([A-Za-z0-9_]+)")
    set(symbol "${CMAKE_MATCH_1}")
    string(APPEND exports "${symbol}\n")
    if(symbol MATCHES "^EGL_(.+)")
      list(APPEND egl_aliases "egl${CMAKE_MATCH_1}=${symbol}")
    endif()
  endif()
endforeach()
if(NOT egl_aliases)
  message(FATAL_ERROR "ARM64 ANGLE exports were not found")
endif()
set_property(GLOBAL PROPERTY OPLAYER_ARM64_EGL_ALIASES "${egl_aliases}")
file(WRITE "${ANGLE_SRC}/ANGLE.def" "${exports}")
file(MAKE_DIRECTORY "${ANGLE_SRC}/lib")
execute_process(COMMAND "${CMAKE_AR}" /nologo /MACHINE:ARM64 "/DEF:${ANGLE_SRC}/ANGLE.def"
  "/OUT:${ANGLE_SRC}/lib/libEGL.dll.lib" COMMAND_ERROR_IS_FATAL ANY)
configure_file("${ANGLE_SRC}/lib/libEGL.dll.lib" "${ANGLE_SRC}/lib/libGLESv2.dll.lib" COPYONLY)

# desktop_webview_window's bundled loader is x64; use Microsoft's ARM64 loader.
set(webview_archive "${CMAKE_BINARY_DIR}/webview2-arm64.nupkg")
oplayer_verified_download(
  "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4258.31/microsoft.web.webview2.1.0.4258.31.nupkg"
  "56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9" "${webview_archive}")
file(ARCHIVE_EXTRACT INPUT "${webview_archive}" DESTINATION "${CMAKE_BINARY_DIR}/webview2-arm64")
set_property(GLOBAL PROPERTY OPLAYER_ARM64_WEBVIEW_DIR "${CMAKE_BINARY_DIR}/webview2-arm64/build/native/arm64")
