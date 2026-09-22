# CrossTransfer desktop app (Flutter)

> 商用构建必须指定 `CT_SERVICE_HOST`；本页的回环/模拟器验收需先设置 `CT_DEVELOPER_MODE=y`（PowerShell：`$env:CT_DEVELOPER_MODE="y"`），仅供内部开发。详见[服务发行配置](../docs/CLIENT_SERVICE.md)。

Requires the native core to be built first (from the repo root):

See [desktop build and packaging](../docs/DESKTOP_BUILD.md) for macOS DMG,
Windows NSIS, Linux deb, signing, and CI validation.

```sh
tools/build_native.sh            # host platform; copies into app/<plat>/native/
cd app && flutter pub get
dart run ffigen --config ffigen.yaml   # only after core/include/crosstransfer/ct_api.h changes
flutter run -d macos             # or: flutter build macos --release
```

Layout:

- `lib/ffi/`      generated bindings + `CoreClient`
- `lib/state/`    Riverpod providers, models, formatting
- `lib/ui/`       send / receive / settings pages and the shell
- `lib/platform/` tray, notifications, link scheme, paths
- `lib/i18n/`     zh / en strings
- `tool/ffi_smoke.dart`  headless FFI check: `CT_NATIVE_LIB=../build/macosx/arm64/release/libcrosstransfer_native.dylib dart run tool/ffi_smoke.dart share <path>`

Environment overrides for development: `CT_DATA_DIR` (core data dir), `CT_NATIVE_LIB` (explicit library path).
