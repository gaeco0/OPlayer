# InAppWebView 0.6.0 keeps its WinRT compositor alive until DLL_PROCESS_DETACH.
# Release it while the UI apartment/dispatcher still exist. Generate patched
# build sources rather than modifying the user's shared pub cache.
if(TARGET flutter_inappwebview_windows_plugin)
  set(webview_target flutter_inappwebview_windows_plugin)
  get_target_property(webview_root ${webview_target} SOURCE_DIR)
  get_target_property(webview_sources ${webview_target} SOURCES)
  set(webview_patched_sources "")
  set(webview_patch_count 0)
  foreach(source IN LISTS webview_sources)
    get_filename_component(name "${source}" NAME)
    if(name STREQUAL "in_app_webview_manager.cpp" OR name STREQUAL "flutter_inappwebview_windows_plugin.cpp")
      if(IS_ABSOLUTE "${source}")
        set(original "${source}")
      else()
        set(original "${webview_root}/${source}")
      endif()
      file(READ "${original}" code)
      set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${original}")
      math(EXPR webview_patch_count "${webview_patch_count} + 1")
      if(name STREQUAL "in_app_webview_manager.cpp")
        set(before "    UnregisterClass(windowClass_.lpszClassName, nullptr);")
        set(after "    compositor_ = nullptr;
    graphics_context_.reset();
    dispatcher_queue_controller_ = nullptr;
    rohelper_.reset();
    valid_ = false;
    UnregisterClass(windowClass_.lpszClassName, nullptr);")
      else()
        set(before "    webViewEnvironmentManager = nullptr;
    inAppWebViewManager = nullptr;
    inAppBrowserManager = nullptr;
    headlessInAppWebViewManager = nullptr;
    cookieManager = nullptr;")
        set(after "    headlessInAppWebViewManager = nullptr;
    inAppBrowserManager = nullptr;
    cookieManager = nullptr;
    inAppWebViewManager = nullptr;
    webViewEnvironmentManager = nullptr;")
      endif()
      string(REPLACE "\r\n" "\n" code "${code}")
      string(FIND "${code}" "${before}" found)
      if(found EQUAL -1)
        message(FATAL_ERROR "WebView lifetime patch needs review after dependency update: ${name}")
      endif()
      string(REPLACE "${before}" "${after}" code "${code}")
      set(patched "${CMAKE_CURRENT_BINARY_DIR}/webview_lifetime/${name}")
      set(previous "")
      if(EXISTS "${patched}")
        file(READ "${patched}" previous)
      endif()
      if(NOT previous STREQUAL code)
        file(WRITE "${patched}" "${code}")
      endif()
      list(APPEND webview_patched_sources "${patched}")
      get_filename_component(original_dir "${original}" DIRECTORY)
      target_include_directories(${webview_target} PRIVATE "${original_dir}")
    else()
      list(APPEND webview_patched_sources "${source}")
    endif()
  endforeach()
  if(NOT webview_patch_count EQUAL 2)
    message(FATAL_ERROR "WebView lifetime patch expected two source files; review dependency changes")
  endif()
  set_property(TARGET ${webview_target} PROPERTY SOURCES "${webview_patched_sources}")
endif()
