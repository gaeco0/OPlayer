# Use one authenticated downloader for CMake and Python build dependencies.
# The helper checks cached files and never forwards API auth to asset redirects.
function(oplayer_github_asset repository asset_id expected destination)
  set(algorithm sha256)
  if(ARGC GREATER 4)
    set(algorithm "${ARGV4}")
  endif()
  find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)
  execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/github_asset.py"
      "${repository}" "${asset_id}" "${expected}" "${destination}" --algorithm "${algorithm}"
    COMMAND_ERROR_IS_FATAL ANY)
endfunction()
