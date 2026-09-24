# CrossTransfer

[中文](README.md)

A proprietary P2P file-transfer application for Windows, macOS, Linux, iOS and Android. Send files or folders using a take-code, app link or QR code.

- Flutter UI and Dart FFI over a shared C++ core and a data-only MiniRTC engine maintained in this repository.
- Direct P2P, TURN over UDP, and WSS relay fallback, with DTLS-SRTP protecting file traffic.
- English and Chinese UI, directories and empty files, progress, cancellation, resume and multi-receiver shares.
- A notification inbox with unread markers and reconnect catch-up; the server admin console publishes, revokes and persists announcements.
- A desktop Quick Drop basket opens from the tray and turns dropped files or folders directly into a take-code.
- Mobile system sharing, native QR scanning, export and imported-copy cleanup; Android foreground service and limited iOS background execution.
- Publisher-operated Go signaling service with automatic client connection with no accounts or file storage. The first version trusts server-forwarded DTLS fingerprints; SPAKE2 authentication is not implemented.

Phase 5 hardening is in progress. See [current status](CLAUDE.md) and [validation notes](docs/PHASE5_NOTES.md). Production signing, domains and physical-device acceptance remain pending. Current packages are development/test artifacts.

## Build and run

Use xmake, a C++17 toolchain, Go 1.25 and Flutter 3.47.5. Platform requirements and commands:

- [Desktop builds and packaging](docs/DESKTOP_BUILD.md)
- [iOS builds and identity configuration](docs/IOS_BUILD.md)
- [Android SDK, NDK and builds](docs/ANDROID_BUILD.md)
- [Self-hosting, TLS, ACME and mobile links](docs/SELF_HOSTING.md)

```sh
xmake f -m release --ct_developer=y --ct_cli=y --ct_tests=y -y
xmake build -y core_tests ct_cli
xmake run core_tests
```

Run the development server in a separate terminal:

```sh
cd server
go test -race ./...
go vet ./...
CT_LISTEN=127.0.0.1:8080 CT_TURN_PORT=0 go run ./cmd/ctserver
```

The CLI is in `build/<platform>/<arch>/release/ct_cli` (`.exe` on Windows). Run `ct_cli share <path> --server 127.0.0.1:8080`, then `ct_cli receive <code> --dir <destination> --server 127.0.0.1:8080` in another terminal. Public-network deployments require trusted TLS and the CLI's `--tls` option.

## Documentation and licensing

[Plan](docs/PLAN.md) · [Signaling](docs/SIGNALING.md) · [Transfer protocol](docs/TRANSFER_PROTOCOL.md) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [License audit](docs/LICENSE_AUDIT.md)

CrossTransfer is covered by its [proprietary license](LICENSE). Third-party components retain their own licenses. Complete distribution notices and the in-app legal page are being completed in phase 5.

Commercial service endpoints are supplied by the publisher at build time and cannot be configured by end users. The production domain is pending. See [client service build configuration](docs/CLIENT_SERVICE.md). The loopback commands above are for internal development only.
