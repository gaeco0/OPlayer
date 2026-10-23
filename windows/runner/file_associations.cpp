#include "file_associations.h"

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <string>

namespace {
bool SetString(const std::wstring& path, const wchar_t* name,
               const std::wstring& value) {
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  const auto status = RegSetValueExW(key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}
}

bool RegisterMediaFileAssociations() {
  wchar_t path[32768];
  const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
  if (!length || length >= 32768) return false;
  const std::wstring executable(path, length);
  const std::wstring command = L"\"" + executable + L"\" \"%1\"";
  const std::wstring icon = L"\"" + executable + L"\",0";
  const std::wstring capabilities = L"Software\\OPlayer\\Capabilities";
  const std::wstring progId = L"Software\\Classes\\OPlayer.Media";
  bool ok = SetString(progId, nullptr, L"OPlayer Media") &&
      SetString(progId + L"\\DefaultIcon", nullptr, icon) &&
      SetString(progId + L"\\shell\\open\\command", nullptr, command) &&
      SetString(capabilities, L"ApplicationName", L"OPlayer") &&
      SetString(capabilities, L"ApplicationDescription", L"OPlayer video, audio and photo viewer") &&
      SetString(capabilities, L"ApplicationIcon", icon);
  const wchar_t* extensions[] = {
      L".mp4", L".mkv", L".avi", L".mov", L".wmv", L".flv", L".webm", L".m4v",
      L".ts", L".m2ts", L".mts", L".3gp", L".mpg", L".mpeg", L".vob", L".ogv", L".rmvb", L".asf",
      L".mp3", L".m4a", L".aac", L".flac", L".wav", L".ogg", L".opus", L".wma", L".aiff", L".alac", L".mka", L".m3u8",
      L".jpg", L".jpeg", L".png", L".webp", L".gif", L".bmp", L".avif"};
  for (const auto* extension : extensions) {
    ok = SetString(capabilities + L"\\FileAssociations", extension, L"OPlayer.Media") && ok;
    // Offer Open With without overwriting the user's existing default/UserChoice.
    HKEY key;
    const std::wstring openWith = std::wstring(L"Software\\Classes\\") + extension + L"\\OpenWithProgids";
    if (RegCreateKeyExW(HKEY_CURRENT_USER, openWith.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
      ok = (RegSetValueExW(key, L"OPlayer.Media", 0, REG_NONE, nullptr, 0) == ERROR_SUCCESS) && ok;
      RegCloseKey(key);
    } else ok = false;
  }
  if (ok) ok = SetString(L"Software\\RegisteredApplications", L"OPlayer", capabilities);
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  return ok;
}

bool OpenDefaultAppsSettings() {
  if (!RegisterMediaFileAssociations()) return false;
  const auto result = ShellExecuteW(nullptr, L"open",
      L"ms-settings:defaultapps?registeredAppUser=OPlayer", nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(result) > 32;
}
