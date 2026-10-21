# OPlayer runtime changes

Vendored from quickjs_engine 0.1.6 (MIT; see LICENSE), including QuickJS-NG 0.14.0
(license notices are retained in native/cxx/quickjs source headers).
Upstream: https://pub.dev/packages/quickjs_engine.

- The native jsNewRuntime bridge now consumes the existing Dart timeout argument
  (milliseconds). A per-runtime, per-thread interrupt deadline is reset at each
  jsEval and also bounds the subsequent pending-job loop. OPlayer uses 200ms and
  a 32MB heap limit, and creates/disposes a runtime for each call.
- Dispose removes the Dart channel registry entry.
- macOS CocoaPods compiles the same source forwarders as SwiftPM and iOS; no
  unpatched prebuilt engine binary is shipped.
- Test library discovery includes the app's build/plugin-runtime directory.
- Unused JS fetch assets are omitted; OPlayer supplies a host-scoped request API.

The runtime has no filesystem/native bridge in the OPlayer API. In-page scripts
are WebView user scripts with access to matching page contents; only trusted
extensions should be installed. Network grants and SHA-256 are validated by the
host before requests or installation.
