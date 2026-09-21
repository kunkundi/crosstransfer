# Third-party notices

CrossTransfer is proprietary software (see `LICENSE`). It embeds or links the
components below. Every dependency permits closed-source static linking; no
GPL or LGPL code is included. License texts of packages fetched by xmake are
available in their upstream repositories and are bundled with binary releases
by the release pipeline (`tools/` in later phases).

## Bundled source (in this repository)

| Component | Location | License | Notes |
| --- | --- | --- | --- |
| WebRTC-derived congestion control, pacing, RTP/RTCP helpers | `minirtc/src/common`, `minirtc/src/qos`, `minirtc/src/rtp/rtp_packet/rtp_packet_received.*`, `rtp_packet_to_send.*`, `minirtc/src/rtcp/congestion_control_feedback.*`, `minirtc/src/qos/transport_feedback_adapter.*` | BSD-3-Clause + patent grant | `minirtc/thirdparty/webrtc/LICENSE`, `minirtc/thirdparty/webrtc/PATENTS` |

## Native dependencies (fetched by xmake, statically linked)

| Package | Version | License | Purpose |
| --- | --- | --- | --- |
| libjuice | 1.7.2 | MPL-2.0 | ICE / STUN / TURN-UDP |
| miniupnpc | 2.3.3 | BSD-3-Clause | UPnP IGD port mapping |
| OpenSSL | 3.3.2 | Apache-2.0 | DTLS, TLS for WSS |
| libsrtp | 2.7.0 | BSD-3-Clause | SRTP / SRTCP |
| KCP | 1.7 | MIT | reliable stream |
| websocketpp | 0.8.2 | BSD-3-Clause | WebSocket client |
| asio | 1.32.0 | BSL-1.0 | networking |
| spdlog | 1.14.1 | MIT | logging |
| nlohmann_json | 3.11.3 | MIT | JSON |

MPL-2.0 note: libjuice is used unmodified. If the project ever patches libjuice
source files, those modified files (and only those) must be made available
under MPL-2.0.

## Server dependencies (Go modules, statically linked)

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

## Flutter QR scanner added in Phase 3

mobile_scanner 7.4.2 — BSD-3-Clause. Source: https://github.com/juliansteenbakker/mobile_scanner

BSD 3-Clause License

Copyright (c) 2022, Julian Steenbakker
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
