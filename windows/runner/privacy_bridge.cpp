#include "privacy_bridge.h"

#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>
#include <UserConsentVerifierInterop.h>
#include <atomic>
#include <map>
#include <mutex>
#include <thread>
#include <bcrypt.h>

namespace {
constexpr UINT kPrivacyResult = WM_APP + 7942;
constexpr UINT kHashResult = WM_APP + 7943;
using Result = flutter::MethodResult<flutter::EncodableValue>;
using namespace winrt::Windows::Security::Credentials::UI;
}

struct PrivacyBridge::State {
  HWND window;
  std::atomic<bool> alive{true};
  UINT_PTR next_id = 1;
  UINT_PTR authentication = 0;
  winrt::Windows::Foundation::IAsyncInfo operation{nullptr};
  std::map<UINT_PTR, std::unique_ptr<Result>> results;
  std::mutex hash_mutex;
  std::map<UINT_PTR, std::vector<uint8_t>> hashes;
};

PrivacyBridge::PrivacyBridge(HWND window, flutter::BinaryMessenger* messenger)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  ApplyCapture(false, false, true); // Protect startup until Dart loads the saved policy.
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "oplayer/privacy", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "deriveLockHash") {
      const auto* values = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!values) { result->Error("ARGUMENT", "Invalid credential parameters"); return; }
      const auto value_it = values->find(flutter::EncodableValue("value"));
      const auto salt_it = values->find(flutter::EncodableValue("salt"));
      const auto* value = value_it == values->end() ? nullptr : std::get_if<std::string>(&value_it->second);
      const auto* salt = salt_it == values->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&salt_it->second);
      if (!value || value->size() > 64 || !salt || salt->size() != 32) {
        result->Error("ARGUMENT", "Invalid credential parameters"); return;
      }
      const auto id = state_->next_id++;
      state_->results.emplace(id, std::move(result));
      std::thread([state = state_, id, password = *value, salt = *salt]() mutable {
        BCRYPT_ALG_HANDLE algorithm = nullptr;
        std::vector<uint8_t> hash(32);
        NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG);
        if (status >= 0) {
          status = BCryptDeriveKeyPBKDF2(algorithm, reinterpret_cast<PUCHAR>(password.data()),
              static_cast<ULONG>(password.size()), salt.data(), static_cast<ULONG>(salt.size()),
              210000, hash.data(), static_cast<ULONG>(hash.size()), 0);
          BCryptCloseAlgorithmProvider(algorithm, 0);
        }
        SecureZeroMemory(password.data(), password.size());
        if (status < 0) hash.clear();
        std::lock_guard<std::mutex> lock(state->hash_mutex);
        if (!state->alive.load()) return;
        state->hashes.emplace(id, std::move(hash));
        PostMessage(state->window, kHashResult, static_cast<WPARAM>(id), 0);
      }).detach();
      return;
    }
    if (call.method_name() == "getCaptureProtection") {
      result->Success(flutter::EncodableValue(manual_capture_)); return;
    }
    if (call.method_name() == "setCaptureProtection") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("ARGUMENT", "Expected a boolean"); return; }
      if (!ApplyCapture(*enabled, app_lock_, shielded_)) {
        result->Error("CAPTURE", "Cannot change Windows capture protection"); return;
      }
      result->Success(); return;
    }
    if (call.method_name() == "setLockPolicy") {
      const auto* values = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!values) { result->Error("ARGUMENT", "Expected a lock policy"); return; }
      auto read = [&](const char* name) {
        const auto found = values->find(flutter::EncodableValue(name));
        return found != values->end() && std::holds_alternative<bool>(found->second) && std::get<bool>(found->second);
      };
      if (!ApplyCapture(read("preventCapture"), read("appLock"), read("shielded"))) {
        result->Error("CAPTURE", "Cannot apply Windows capture protection"); return;
      }
      result->Success(); return;
    }
    if (call.method_name() == "cancelAuthentication") {
      CancelAuthentication(); result->Success(); return;
    }
    const bool authenticate = call.method_name() == "authenticate";
    if (!authenticate && call.method_name() != "biometricAvailable") { result->NotImplemented(); return; }
    if (authenticate && state_->authentication != 0) {
      result->Success(flutter::EncodableValue(false)); return;
    }
    const auto id = state_->next_id++;
    state_->results.emplace(id, std::move(result));
    const std::weak_ptr<State> weak = state_;
    auto finish = [weak, id](bool verified) {
      if (auto state = weak.lock(); state && state->alive.load()) {
        PostMessage(state->window, kPrivacyResult, static_cast<WPARAM>(id), verified ? 1 : 0);
      }
    };
    try {
      if (!authenticate) {
        auto operation = UserConsentVerifier::CheckAvailabilityAsync();
        operation.Completed([finish](const auto& completed, winrt::Windows::Foundation::AsyncStatus status) {
          bool available = false;
          try { available = status == winrt::Windows::Foundation::AsyncStatus::Completed && completed.GetResults() == UserConsentVerifierAvailability::Available; }
          catch (...) {}
          finish(available);
        });
      } else {
        const winrt::hstring message{L"Unlock OPlayer with Windows Hello"};
        auto interop = winrt::get_activation_factory<UserConsentVerifier, IUserConsentVerifierInterop>();
        auto operation = winrt::capture<winrt::Windows::Foundation::IAsyncOperation<UserConsentVerificationResult>>(
            interop, &IUserConsentVerifierInterop::RequestVerificationForWindowAsync,
            state_->window, reinterpret_cast<HSTRING>(winrt::get_abi(message)));
        state_->authentication = id;
        state_->operation = operation;
        operation.Completed([finish](const auto& completed, winrt::Windows::Foundation::AsyncStatus status) {
          bool verified = false;
          try { verified = status == winrt::Windows::Foundation::AsyncStatus::Completed && completed.GetResults() == UserConsentVerificationResult::Verified; }
          catch (...) {}
          finish(verified);
        });
      }
    } catch (...) { finish(false); }
  });
}

bool PrivacyBridge::ApplyCapture(bool manual, bool app_lock, bool shielded) {
  const bool secure = manual || app_lock || shielded;
  if (!SetWindowDisplayAffinity(state_->window, secure ? 0x00000011 : WDA_NONE)) {
    if (!secure || !SetWindowDisplayAffinity(state_->window, WDA_MONITOR)) return false;
  }
  manual_capture_ = manual; app_lock_ = app_lock; shielded_ = shielded;
  return true;
}

bool PrivacyBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kHashResult) {
    const auto id = static_cast<UINT_PTR>(wparam);
    std::vector<uint8_t> hash;
    {
      std::lock_guard<std::mutex> lock(state_->hash_mutex);
      auto found = state_->hashes.find(id);
      if (found != state_->hashes.end()) { hash = std::move(found->second); state_->hashes.erase(found); }
    }
    auto result = state_->results.find(id);
    if (result != state_->results.end()) {
      if (hash.size() == 32) result->second->Success(flutter::EncodableValue(hash));
      else result->second->Error("HASH", "Credential verification failed");
      state_->results.erase(result);
    }
    return true;
  }
  if (message != kPrivacyResult) return false;
  const auto id = static_cast<UINT_PTR>(wparam);
  auto found = state_->results.find(id);
  if (found == state_->results.end()) return true;
  found->second->Success(flutter::EncodableValue(lparam != 0));
  state_->results.erase(found);
  if (state_->authentication == id) {
    state_->authentication = 0;
    state_->operation = nullptr;
  }
  return true;
}

void PrivacyBridge::CancelAuthentication() {
  const auto id = state_->authentication;
  if (state_->operation) { try { state_->operation.Cancel(); } catch (...) {} }
  state_->operation = nullptr;
  state_->authentication = 0;
  const auto found = state_->results.find(id);
  if (found != state_->results.end()) {
    found->second->Success(flutter::EncodableValue(false));
    state_->results.erase(found);
  }
}

PrivacyBridge::~PrivacyBridge() {
  state_->alive.store(false);
  CancelAuthentication();
  for (auto& entry : state_->results) entry.second->Success(flutter::EncodableValue(false));
  state_->results.clear();
  channel_->SetMethodCallHandler(nullptr);
}
