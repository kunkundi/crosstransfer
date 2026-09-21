# Third-party notices

CrossTransfer is proprietary software (see `LICENSE`). It embeds or links the
components below. The project prohibits GPL/LGPL runtime dependencies. The
complete transitive inventory and bundled notices are still being completed;
see `docs/LICENSE_AUDIT.md` for the current evidence and remaining items.

## Bundled source (in this repository)

| Component | Location | License | Notes |
| --- | --- | --- | --- |
| WebRTC-derived congestion control, pacing, RTP/RTCP helpers | `minirtc/src/common`, `minirtc/src/qos`, `minirtc/src/rtp/rtp_packet/rtp_packet_received.*`, `rtp_packet_to_send.*`, `minirtc/src/rtcp/congestion_control_feedback.*`, `minirtc/src/qos/transport_feedback_adapter.*` | BSD-3-Clause + patent grant | `minirtc/thirdparty/webrtc/LICENSE`, `minirtc/thirdparty/webrtc/PATENTS` |

## Native dependencies (fetched by xmake, statically linked)

| Package | Version | License | Purpose |
| --- | --- | --- | --- |
| libjuice | 1.7.2 + CrossTransfer ct1 | MPL-2.0 | ICE / STUN / TURN-UDP; opt-in relay-only policy |
| miniupnpc | 2.3.3 | BSD-3-Clause | UPnP IGD port mapping |
| OpenSSL | 3.5.8 | Apache-2.0 | DTLS, TLS for WSS |
| libsrtp | 2.7.0 | BSD-3-Clause | SRTP / SRTCP |
| KCP | 1.7 | MIT | reliable stream |
| websocketpp | 0.8.2 | BSD-3-Clause | WebSocket client |
| asio | 1.32.0 | BSL-1.0 | networking |
| spdlog | 1.14.1 | MIT | logging |
| nlohmann_json | 3.11.3 | MIT | JSON |

MPL-2.0 source notice: libjuice covered source, including our ct1 changes, is
available under MPL-2.0 in `libjuice-1.7.2-ct1.tar.gz`. Desktop packages include
this archive alongside these notices; mobile/Flutter bundles include it in
`assets/legal/` (APK path: `assets/flutter_assets/assets/legal/`). The archive
contains the complete corresponding source and `CROSSTRANSFER-CHANGES.txt`.
Its SHA-256 is `916a4d3cf32cd8ab4fdca2f7a6b39d94b90e1915471030850abaa26833e11c25`.
Repository copy: `app/assets/legal/libjuice-1.7.2-ct1.tar.gz`; full license:
`docs/licenses/libjuice.txt`. Upstream: https://github.com/paullouisageneau/libjuice/tree/v1.7.2.
The changes add `juice_config_t.relay_only` and reject non-relayed local
candidate pairs when enabled. No additional restriction in CrossTransfer's
proprietary license limits recipients' rights to this covered source under MPL.
Distributing even an unmodified compiled MPL library requires informing
recipients how to obtain its corresponding covered source.

## Server dependencies (Go modules, statically linked)

The standalone server embeds its full module copyright/license texts and the Go
runtime license; run `ctserver -licenses` to read them (container: `docker run
--rm <image> -licenses`). The version/source/checksum inventory is
`docs/licenses/go_manifest.json`; `tools/check_go_notices.py` verifies it against
the modules selected in `server/go.mod`.

| Module | License |
| --- | --- |
| github.com/pion/turn/v4 (+ pion/stun, pion/dtls, pion/transport, pion/logging, pion/randutil) | MIT |
| github.com/coder/websocket | ISC |
| golang.org/x/time, golang.org/x/crypto, golang.org/x/net, golang.org/x/sys, golang.org/x/text | BSD-3-Clause |
| gopkg.in/yaml.v3 | MIT / Apache-2.0 |
| github.com/wlynxg/anet | BSD-3-Clause |

## Removed from the MiniRTC baseline

glib, gupnp / gssdp / libsoup / libxml2 / libpsl, libnice (LGPL) and all media
codecs (openh264, dav1d, SVT-AV1, aom, libyuv, NVIDIA codec SDK, openfec,
libopus) as well as libdatachannel are not part of this project.

## Mobile QR scanning

Android uses ZXing Android Embedded 4.3.0 (Journey Mobile, Inc. and contributors)
and ZXing Core 3.4.1 (ZXing authors), both Apache-2.0. Full upstream license texts:
`docs/licenses/zxing-android-embedded.txt` and `docs/licenses/zxing-core.txt`.
Sources: https://github.com/journeyapps/zxing-android-embedded and https://github.com/zxing/zxing.
iOS uses the system AVFoundation framework. mobile_scanner and Google ML Kit
are no longer included.
