# 特化版 MiniRTC

数据专用的 P2P 传输引擎，供 `core/` 通过 `src/api/minirtc.h` 的 C API 使用。

## 结构

| 目录 | 内容 |
| --- | --- |
| `src/api` | 公开 C API（`minirtc.h`）与包装 |
| `src/pc` | 信令客户端与会话状态机（协议 v1，见 `docs/SIGNALING.md`） |
| `src/ice` | `IceAgent`（libjuice 封装 + miniupnpc 端口映射）、`DtlsTransport`（OpenSSL DTLS 1.2 + SRTP 密钥导出） |
| `src/transport` | `DataTransport`：命名数据流（KCP 可靠 / 原始非可靠）、SRTP、PacedSender、发送端延迟型 BWE、接收端 RFC 8888 反馈；`paced_sender/` |
| `src/qos` `src/common` | WebRTC 派生的拥塞控制与工具类（BSD-3） |
| `src/rtp` `src/rtcp` `src/srtp` | 通用 RTP 打包、RTCP CCFB、libsrtp 封装 |
| `src/ws` | websocketpp 客户端（ws/wss、文本+二进制、重连、系统信任库） |
| `examples/data_echo` | 端到端验证程序；`examples/run_echo.sh` 一键跑两端 |

## 数据路径

```
MiniRtcSend ─▶ DataTransport::Send
   reliable   ─▶ KCP ─▶ RTP(PT 121) ─┐
   unreliable ─▶ RTP(PT 120) ────────┼─▶ PacedSender ─▶ SRTP protect ─▶ path
                                     │                                   │
   feedback ◀── RTCP CCFB ◀──────────┘          ICE(libjuice) / WSS relay
```

- 非可靠流每次 `MiniRtcSend` 一个报文（≤ 1150 字节），进入 pacer；pacer 队列超过 400 ms 时 `MiniRtcSend` 返回 1（回压）。
- 可靠流按 KCP 窗口回压（默认 1024，`MiniRtcSetReliableWindow` 可调）。
- 接收端对每个 RTP 包生成 RFC 8888 反馈（25–250 ms），发送端 `TransportFeedbackAdapter` → `CongestionControl`（延迟型 + 丢包型）→ pacer 速率与 `MiniRtcGetLinkEstimate`。
- pacing factor 1.15（视频版为 2.5），有界队列不超速排空。
- 连通性：P2P → TURN-UDP（`MINIRTC_TURN_AUTO`）→ ICE 失败或超时后 WSS 中继（`enable_ws_relay`）。`force_ws_relay` 跳过 ICE。
- DTLS-SRTP（AES-128-GCM）在任何路径上都启用；接收端（offerer）是 DTLS client；指纹经信令交换。

## 构建

```sh
cd minirtc
xmake f -m release -y && xmake build -y          # macOS / Linux / Windows
xmake f -p iphoneos -a arm64 -m release -y -o build-ios && xmake build -y
```

依赖全部由 xmake 拉取并静态链接：libjuice、miniupnpc（本仓库 `thirdparty/miniupnpc` 配方）、openssl3、libsrtp、kcp、websocketpp、asio、spdlog、nlohmann_json。许可证见根 `THIRD_PARTY_NOTICES.md`。

## 验证

先启动本地服务端：

```sh
cd server && go build -o /tmp/ctserver ./cmd/ctserver
CT_LISTEN=127.0.0.1:8080 CT_PUBLIC_IP=127.0.0.1 CT_TURN_SECRET=test /tmp/ctserver
```

然后：

```sh
examples/run_echo.sh p2p                       # 直连
examples/run_echo.sh turn  --turn force        # 强制 TURN
examples/run_echo.sh relay --relay-only        # WSS 中继
examples/run_echo.sh nosrtp --no-srtp
MINIRTC_TEST_DROP_PERCENT=5   examples/run_echo.sh loss5 --turn off
MINIRTC_TEST_LINK_KBPS=8000   examples/run_echo.sh cap8m --turn off --seconds 8
```

`MINIRTC_TEST_*` 是仅供测试的出向链路损伤开关（丢包率 / 限速），在 `peer_connection.cpp` 的路径发送函数处生效。
