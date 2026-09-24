# CrossTransfer 完整规划（v7，2026-09-21）

## 一、目标与约束

在 `/Users/dijunkun/SourceCode/crosstransfer` 新建一款**商业闭源**的 P2P 文件传输工具，覆盖 Windows / macOS / Linux / iOS / Android。客户端、服务端、传输引擎全部在本仓库内自主实现。

已确定的约束：

1. UI 用 **Flutter + Dart FFI**，一套界面覆盖全平台。
2. 传输引擎用 **MiniRTC 特化版**，源码放在本仓库 `minirtc/` 维护；裁掉音视频，保留信令 / ICE / DTLS-SRTP / RTP 数据通道 / KCP，并按需改造。
3. 服务端**完全重写**，放在本仓库 `server/`，使用 **Go**；信令协议由本项目自行定义。
4. 核心逻辑**全部新写**，不从 CrossDesk 复制后改；CrossDesk 只作为架构与协议事实的参考。
5. 交互为**取件码模式**：发送端选文件后生成取件码 / 链接 / 二维码，接收端输入即收。
6. 传输协议分工：**控制消息走 KCP 可靠流；文件数据走自研"按偏移传块 + 位图 SACK"协议**，跑在非可靠流上。
7. **商业闭源**：随 App 编译或分发的第三方依赖必须允许闭源链接（iOS 原生传输库必须静态）；禁止 GPL/LGPL 运行库。唯一系统库例外：Linux 界面动态链接由发行版提供、未修改、不随 App 打包的 GTK/GLib。ICE 层仍以 libjuice（MPL-2.0）替换 libnice / glib / gupnp。

已逐项确认的设计决策：

| # | 决策 |
| --- | --- |
| 1 | 取件码 10 位 Crockford Base32（4 位前缀 + 6 位密钥，50 bit）；UI 链接/二维码优先、手输兜底 |
| 2 | 断线续传用 `resume_token`；`once` 码失效后仍可凭 token 恢复 |
| 3 | 第一版 DTLS-SRTP、信任服务器转发的指纹；协议预留 `auth` 字段供 SPAKE2 升级 |
| 4 | 输入取件码即视为同意，`offer` 到达直接开始；进度页可取消 |
| 5 | 客户端无账号、服务端单实例；传输状态仅在内存，不存文件；运营通知独立持久化，管理端由独立密钥保护；`claim` 限速；TURN 内嵌 pion/turn，可切外部 coturn |
| 6 | 固定由接收端发 offer |
| 7 | 全部专有许可；依赖允许 MPL / BSD / Boost / Apache / MIT，以及已审计的 ISC、Unicode/ICU、Zlib、libpng、FTL/IJG、public-domain；Linux GTK/GLib 仅限系统动态链接例外；ICE 使用 libjuice + miniupnpc；无 ICE-TCP / TURN-TCP，由 WSS 中继兜底 |
| 8 | 第一版不做浏览器接收页，落地页仅"用 App 打开 / 下载" |
| 9 | 非可靠流接 PacedSender + BWE，块净荷 ≤ 1100 字节；ctrl 走 KCP 窗口 1024；BWE 为主、SACK 丢包 AIMD 兜底 |
| 10 | iOS 传输期间 `beginBackgroundTask`，大文件需前台；Android 前台服务 |
| 11 | UI 中 / 英双语；应用名 CrossTransfer；bundle id 与域名在 Flutter 阶段前由用户提供 |
| 12 | 商用客户端的服务由发行方统一管理。服务域名在原生库构建时注入，固定 WSS/443、自动选择传输路径；UI 不展示服务器、TLS、TURN、中继等配置，也不引导用户部署服务。正式构建忽略旧配置中的连接参数，运行时拒绝修改，配置查询与持久化不包含连接参数。仅显式开发构建保留内部联调能力。 |

执行假设：

| 项 | 假设 |
| --- | --- |
| Android | 分阶段，特化版 MiniRTC 需补 NDK 构建（libjuice / OpenSSL / libsrtp 交叉编译，无 glib 后难度明显降低） |
| 许可 | 项目、`minirtc/` 特化版、`server/` 均为专有许可。MiniRTC 版权人（dijunkun = kunkundi）为用户本人；`qos/aimd_rate_control.cc` 中一处外部贡献的一行初始化修复在特化版中重写。仓库根放 `LICENSE`（专有）与 `THIRD_PARTY_NOTICES.md`（汇总依赖许可证文本，随产品分发，App 内关于页提供第三方开源声明入口） |
| 公共服务 | 由发行方部署和运维，正式域名待定；缺少域名时禁止构建商用原生库。部署文档仅供内部运维使用。 |

环境（2026-09-22）：本机有 xmake 3.1.0、Xcode、Go 1.25、Flutter 3.47.5 / Dart 3.13.4、CocoaPods。MiniRTC 基线 commit `a25a3b4` 已复制并裁剪为数据专用版本；桌面构建与验收入口见 `docs/DESKTOP_BUILD.md`。

## 二、总体架构

```text
┌─────────────┐  WSS(JSON)  ┌────────────────────┐  WSS(JSON)  ┌─────────────┐
│  发送端 App  │◀──────────▶│  server (Go)        │◀──────────▶│  接收端 App  │
│ Flutter     │             │ 信令/取件码/TURN/中继 │             │ Flutter     │
│ core (C++)  │             └────────────────────┘             │ core (C++)  │
│ minirtc     │◀════════ ICE(P2P 或 TURN-UDP) + DTLS-SRTP ════▶│ minirtc     │
└─────────────┘        ctrl: KCP 可靠流   data/sack: 块协议      └─────────────┘
                       ICE 失败 → 经 server 的 WSS 中继兜底
```

分层：Flutter（渲染、平台文件访问）→ `core/`（C API，状态机与传输引擎）→ `minirtc/`（信令客户端、ICE、加密、数据通道）→ `server/`（信令、取件码、TURN、中继）。

## 三、服务端 `server/`（Go）

| 模块 | 内容 |
| --- | --- |
| 信令 WSS | 单端点 `/ws`；JSON 消息；每连接一个 goroutine；心跳 30 s；断线即清理其持有的 share / claim |
| 取件码注册表 | 内存表 + 过期清理；10 位 Crockford Base32（4 位前缀 + 6 位密钥），CSPRNG 生成，前缀索引、密钥常量时间比较；`once` / `open` 两种模式 |
| ICE 配置下发 | 返回 STUN 地址与 TURN HMAC 时间凭据（与 coturn REST API 相同算法），凭据有效期 10 分钟 |
| TURN | 默认内嵌 `pion/turn`（UDP；客户端 ICE 仅用 UDP），配置可切换为外部 coturn |
| WSS 中继兜底 | ICE 失败时，会话双方经 `relay` 二进制帧在同一条 WSS 上转发；服务端按 `session_id` 转发、按连接限速；UI 提示"中继模式" |
| 运维 | `/healthz`、结构化日志、可选 Prometheus `/metrics`；TLS 支持自带证书或 ACME；Dockerfile + compose；配置用环境变量 + 可选 YAML |

不做：用户账号、持久身份、传输历史记录、文件中转存储。服务器不接触文件内容。

### 运营通知（2026-09-25）

运营者通过 `/admin/` 管理页使用独立的 `CT_ADMIN_TOKEN` 登录，发布纯文本标题、正文与通知级别，查看最近 50 条记录并撤回。管理接口使用 Bearer 鉴权；未配置密钥时关闭后台。`CT_NOTIFICATION_FILE` 指定通知 JSON 文件，原子替换保存成功后才推送，容器单独挂载数据卷。保留最近 50 条记录（含撤回）；新通知替换最旧记录。

客户端在 `hello` 中声明 `notifications: true`，服务端在 welcome 后、发布或撤回时发送 `notifications{items:[{id,title,body,level,created_at}]}` 完整有效列表。旧客户端不接收此扩展。复用既有 WSS、MiniRTC → core → Flutter 事件链，不增加公共轮询接口。客户端提供通知中心、未读标记、全部已读、本地缓存与系统提醒；重连同步并按 ID 去重，批量补收仅提醒最新一条。服务端撤回或记录超出保留上限后，客户端下次同步移除。操作系统终止/挂起应用时不保证即时到达，下次连接补收；本阶段不接入 APNs/FCM。

### 信令协议 v1

所有消息 `{"type": "...", "id": <请求序号>, ...}`，服务端回复携带同一 `id`；错误统一 `{"type":"error","id":..,"code":"..","message":".."}`。

| 方向 | 消息 | 字段 | 说明 |
| --- | --- | --- | --- |
| C→S | `hello` | `app`, `version`, `platform`, `proto` | 连接后第一条；回 `welcome{peer_id, ice_servers, heartbeat_sec}`，`peer_id` 为本连接的临时随机 ID |
| C→S | `create_share` | `mode`("once"/"open"), `ttl_sec`, `meta`(总大小、文件数，仅展示) | 回 `share_created{share_id, code, expires_at}` |
| C→S | `close_share` | `share_id` | 通知已配对接收端 `share_closed` |
| C→S | `claim` | `code`, `resume_token`(可选) | 校验取件码 → 创建 session，向双方发 `session_start{session_id, role, remote_peer_id, ice_servers, resume_token}`；带 `resume_token` 时恢复中断的 session（即使 `once` 码已失效）；失败码 `code_not_found` / `code_expired` / `share_busy` / `rate_limited` |
| C↔S | `signal` | `session_id`, `to`, `payload{sdp \| candidate \| candidates_done}` | 服务端只按 `session_id` 校验双方身份并转发；`payload` 预留 `auth` |
| C→S | `leave` | `session_id` | 通知对端 `session_end{reason}` |
| C↔S | `relay` | `session_id` + 二进制帧 | ICE 失败后的 WSS 中继数据；服务端仅转发，不解析 |
| C↔S | `ping` / `pong` | | 心跳 |

约束：`claim` 按 IP 与全局限速、失败恒定延迟；`once` 模式首个 `claim` 成功即失效，`open` 模式持续有效直到关闭或过期；发送端保留未完成 session 状态直到 share 过期以支持续传；`session_start` 后固定由接收端发 offer。

## 四、特化版 MiniRTC `minirtc/`

### 依赖与许可证边界（闭源要求）

2026-09-22 所有者明确授权上述既有宽松许可和 Linux 系统 GTK/GLib 例外。该例外不允许将 GTK/GLib 静态链接、修改或复制进安装包，也不允许重新引入已移除的 Android GPL＋Classpath 运行库。Dart `gtk` 与 `dbus` 包自身为 MPL-2.0，完整未修改源码随 App 提供，与 Linux 系统 GTK/GLib 的 LGPL 许可分别记录。

| 依赖 | 许可证 | 处理 |
| --- | --- | --- |
| glib、gupnp / gssdp / libsoup / libxml2 / libpsl、proxy-libintl | LGPL | **移除**（本项目不采用 LGPL 静态链接及其重链接材料方案） |
| libnice（含 MiniRTC 四个补丁） | LGPL-2.1 / MPL-1.1，硬依赖 glib | **移除**，以 libjuice 替代 |
| libjuice | MPL-2.0 | **新增**：纯 C，ICE + STUN + TURN-UDP，零外部依赖 |
| miniupnpc | BSD-3 | **新增**：替代 gupnp 做网关端口映射 |
| OpenSSL 3、libsrtp、websocketpp、asio、KCP、spdlog、nlohmann_json、concurrentqueue | Apache-2.0 / BSD / Boost / MIT | 保留 |
| WebRTC 派生代码（`common/`、`qos/`、部分 RTP/RTCP） | BSD-3 + PATENTS | 保留，附带 LICENSE / PATENTS |

libjuice 不支持 ICE-TCP / TURN-TCP，UDP 被完全封锁的网络由服务端 WSS 中继兜底；libnice 补丁中的"中继后升级 P2P"与"对称 NAT 预测打洞"第一版不保留，后续按需在 libjuice 之上重做。

分发义务：随产品分发 `THIRD_PARTY_NOTICES.md`（各依赖许可证文本、WebRTC PATENTS）；MPL-2.0 无论组件是否修改，均要求提供对应覆盖源码并告知获取方式，修改部分同样保留 MPL-2.0。阶段 5 的 libjuice ct1 完整源码支持离线保存；未修改的 dbus 0.7.15、Dart gtk 2.2.0 通过官方对应版本下载链接获取，源码归档仍随包保留用于校验与备份。App 内设置 → 关于 → 第三方开源声明页面。

### 改造范围

**ICE 层替换**：MiniRTC 的 DTLS 由自身用 OpenSSL 在 ICE socket 之上实现（`ice_agent.cpp` 的 `BIO_s_nice`），与 libnice 无关。替换限于 `ice/ice_agent`：以 libjuice 的 `juice_agent_t` 实现 gather / set remote description / add candidate / send / recv 回调 / state 回调；DTLS、SRTP、RTP、KCP 层不变；`ice/punch_*` 删除；UPnP 映射改用 miniupnpc。

**直接删除**（不加宏）：`src/media/`、`src/frame/`、`src/fec/`、`src/inih/`、`transport/channel/` 的 video / audio 文件、`rtp/` 的 H.264 / AV1 packetizer / depacketizer 与 OBU、`rtcp/` 的 FIR、`pc/datachannel_connection*`、`transport/datachannel_transport*`、`thirdparty/` 中 openh264 / dav1d / svt-av1 / aom / libyuv / nvcodec / openfec / libdatachannel / webrtc / glib / gupnp / libnice 配方及相关 `add_requires`、Apple 媒体 frameworks、`config/`、`tests/`、`ios/`、`doc/`；新增 `thirdparty/libjuice`、`thirdparty/miniupnpc` 配方。

**重写**：

- `pc/peer_connection`：按信令协议 v1 实现客户端侧；去掉 `login / join_transmission` 等旧消息与 INI 配置。
- `transport/ice_transport_controller`：只保留数据流上下文、SRTP 会话表、`PacedSender`、拥塞控制与传输反馈；目标从 3.5k 行降到 < 800 行。
- `transport/ice_transport`：SDP 只含一条 `m=application` 及各数据流的 `a=ssrc` / `a=x-reliable-data`。
- `api/minirtc.h`：重写为数据专用 API。

**数据路径改造**：非可靠流经 `PacedSender` 发送并进入传输反馈，使 `qos/` 延迟型带宽估计对数据流生效并对外暴露；可靠流 KCP 参数可配。

### 新 C API

```c
typedef struct MiniRtcPeer MiniRtcPeer;
typedef struct {
  const char* server_host; int server_port;       // WSS
  const char* log_dir;
  MiniRtcTurnMode turn_mode; bool enable_srtp;
  const char* app; const char* version; const char* platform;   // hello
  OnSignalStatus  on_signal_status;   // Connecting/Connected/Failed/Closed/Reconnecting/TlsError
  OnShareEvent    on_share_event;     // share_created / share_closed / claimed
  OnSessionStatus on_session_status;  // Connecting/Connected/Disconnected/Failed/Closed + reason + relay 标志
  OnReceiveData   on_receive_data;    // (data,len,session_id,stream)
  OnNetStats      on_net_stats;       // bitrate/loss/rtt/bwe/traversal
  void* user_data;
} MiniRtcParams;
MiniRtcPeer* MiniRtcCreate(const MiniRtcParams*);
void MiniRtcDestroy(MiniRtcPeer**);
int  MiniRtcConnect(MiniRtcPeer*);                                        // WSS + hello
int  MiniRtcAddDataStream(MiniRtcPeer*, const char* name, bool reliable);  // connect 前
int  MiniRtcCreateShare(MiniRtcPeer*, const char* mode, int ttl_sec, const char* meta_json);
int  MiniRtcCloseShare(MiniRtcPeer*, const char* share_id);
int  MiniRtcClaim(MiniRtcPeer*, const char* code, const char* resume_token);
int  MiniRtcLeave(MiniRtcPeer*, const char* session_id);
int  MiniRtcSend(MiniRtcPeer*, const char* session_id, const char* stream, const void* data, size_t len);
int  MiniRtcGetLinkEstimate(MiniRtcPeer*, const char* session_id, MiniRtcLinkEstimate* out);  // bwe_bps, rtt_ms, loss
int  MiniRtcSetReliableWindow(MiniRtcPeer*, const char* stream, int wnd);
```

一个 Peer 对应一条 WSS 连接，可同时持有多个 session（`open` 模式）。

验收：macOS / Linux / Windows / iphoneos 编译；`xmake show -t minirtc` 依赖仅剩 libjuice、miniupnpc、websocketpp、asio、openssl、libsrtp、kcp、spdlog、nlohmann_json、concurrentqueue，且全部为 MPL / BSD / Boost / Apache / MIT；`minirtc/examples/data_echo` 两端经本地 `server/` 完成 create_share → claim → P2P / 强制 TURN / WSS 中继 → 可靠与非可靠收发。

## 五、交互与传输协议

### 取件码

- **格式**：10 位 Crockford Base32（去掉 0/O/1/I/L，大小写不敏感），50 bit 熵，CSPRNG 生成；显示为 `XXXXX-XXXXX`，例如 `3K7QW-P9X2M`。
- **结构**：前 4 位路由前缀 + 后 6 位密钥。第一版 `claim` 发送完整码；第二版升级 SPAKE2 后只发前缀，密钥留在两端做口令认证，码格式不变。
- **安全度量**：100 万活跃分享下单次盲猜命中概率约 1/10⁹；配合 `claim` 限速、失败恒定延迟、TTL（`once` 默认 10 分钟，`open` 最长 24 小时）、日志只记前缀。
- **UI 原则：链接 / 二维码优先，手输兜底**。发送页主视觉是二维码与"复制链接 / 系统分享"，取件码次要展示可复制；移动端接收页首屏是"扫码"与"粘贴链接"，桌面端仅保留取件码 / 分享链接输入与粘贴，不显示扫码入口或二维码图标。手输框自动大写、跳过连字符、拒绝混淆字符；移动端输满 10 位自动提交，桌面端手动输入后按 Enter 或点击“接收”提交，单独提供“粘贴并接收”快捷操作；系统链接唤起继续自动接收。
- **链接**：`https://<域名>/r/<code>`（iOS Universal Link / Android App Link 直达接收页）；桌面 `crosstransfer://r/<code>`；落地页只显示"用 App 打开 / 下载"。

### 流程

```text
发送端                          server                           接收端
选文件 → create_share ─────▶ 分配 code/share_id
UI 显示 二维码 / 链接 / 取件码
                                                    扫码 / 点链接 / 输码 → claim{code}
       ◀── session_start ──── 配对 ────── session_start ──▶
       ◀──────── signal(offer/answer/candidate) 经 server 转发 ────────▶
       ◀══════ ICE + DTLS-SRTP 建立（P2P → TURN-UDP，失败则 WSS 中继）══════▶
ctrl: offer{manifest} ────────────────────────────────────▶ 校验后建接收目录
       ◀──────────────────── accept{每文件位图摘要} ─────────
data 按 pacer 速率发块 ────▶ ；◀──── sack 位图/空洞 + 速率/丢包 ──
ctrl: file_done / transfer_done                                校验 SHA-256 → 完成
once 模式：close_share，code 失效
```

- 分享 `once`（默认）/ `open`；`ttl` 默认 10 分钟；未配对超时自动关闭。
- 输入取件码即视为同意，`offer` 到达即开始；进度页展示清单，可取消。
- 两端无持久身份，`peer_id` 每次连接临时分配；续传靠 `resume_token`。

### 安全模型

- 传输层 DTLS-SRTP（沿用 MiniRTC 的 DTLS 密钥导出）；连通性依次为 P2P → TURN-UDP → 服务端 WSS 中继。
- 第一版信任服务器转发的 SDP 指纹（与 WebRTC 同级）；预留 SPAKE2 升级使服务器无法中间人。
- 取件码 50 bit 熵 + 限速 + TTL。

### 流与块协议

| 流名 | 传输 | 内容 |
| --- | --- | --- |
| `ctrl` | KCP 可靠流（窗口 1024） | JSON：`offer`（manifest：相对路径 / 大小 / SHA-256、目录树）、`accept`（每文件位图摘要）、`reject`、`pause`、`resume`、`cancel`、`file_done`、`transfer_done`、`error{code,msg}` |
| `data` | 非可靠流，单包 | 块头 `magic(2) ver(1) flags(1) file_index(2) block_index(4) len(2)` + 净荷 ≤ 1100 字节 |
| `sack` | 非可靠流，单包 | 每 50–100 ms：`file_index`、最高连续已收块、空洞游程列表、接收速率、丢包估计 |

发送端：`Sweep`（按 pacer 速率顺序发全部块）→ `Repair`（按 SACK 空洞重发）→ `file_done`。速率来自 `MiniRtcGetLinkEstimate` 的 BWE，不可用时按 SACK 丢包率 AIMD。接收端 `pwrite` 到 `<name>.ctpart`，位图周期性持久化到 `transfers.json`，完成后校验 SHA-256 改名，同名加后缀。目录用 `/` 相对路径，拒绝绝对路径、`..`、驱动器前缀、控制字符、平台保留名；空文件直接创建；任一侧失败以 `error` 收敛并清理。WSS 中继模式下同一协议经 `relay` 帧承载，块大小不变。

## 六、仓库布局

```text
crosstransfer/
├── xmake.lua                      # minirtc + crosstransfer_core + ct_cli + crosstransfer_native(shared)
├── LICENSE                        # 专有
├── THIRD_PARTY_NOTICES.md         # 依赖许可证汇总（随产品分发）
├── minirtc/                       # 特化版 MiniRTC
│   ├── xmake.lua  src/  thirdparty/(libjuice, miniupnpc, libsrtp, websocketpp)  examples/data_echo  README.md
├── core/                          # crosstransfer_core（C++17，C API）
│   ├── include/crosstransfer/ct_api.h      # 唯一公开头（ffigen 输入）
│   ├── src/api/      C API、事件 JSON
│   ├── src/runtime/  事件循环线程、Peer RAII 封装 + 回调门控、后台销毁队列
│   ├── src/share/    Share / Receive 状态机、取件码与链接编解码
│   ├── src/transfer/ ctrl / 块 / sack 编解码、Sweep/Repair 发送器、位图接收器、SHA-256、续传
│   ├── src/storage/  config.json、transfers.json
│   ├── src/log/
│   └── tests/
├── cli/                           # ct_cli share <paths...> / ct_cli receive <code> --dir
├── server/                        # Go
│   ├── cmd/ctserver
│   ├── internal/{signal, codes, turn, relay, config}
│   ├── Dockerfile  compose.yaml  .env.example
├── app/                           # Flutter
│   ├── lib/{ffi, state, ui, platform}  ffigen.yaml
│   └── linux/ windows/ macos/ ios/ android/
├── tools/build_native.sh / .ps1   # xmake 构建 + 合并 + 复制到 app 各平台目录
├── docs/                          # 架构、信令协议、块协议、构建、部署、第三方许可证清单
├── .github/workflows/
└── README.md  README_EN.md
```

## 七、core 设计

线程模型：MiniRTC 回调 → 门控 → 拷贝 → 投递 core 单线程事件循环；文件 I/O 每传输一个工作线程；UI 只收一个 UTF-8 JSON 事件回调（Dart 用 `NativeCallable.listener`），进度节流 ≤ 10 Hz；所有 `ct_*` 非阻塞。

```c
typedef struct CtCore CtCore;
typedef void (*CtEventCallback)(const char* json_utf8, void* user_data);
CtCore*     CtCreate(const char* config_json);   // 用户偏好；服务器和网络策略由发行配置管理
void        CtDestroy(CtCore*);
void        CtSetEventCallback(CtCore*, CtEventCallback, void* user_data);
void        CtSetEventCallbackOwned(CtCore*, CtEventCallback, void* user_data); // 仅共享库：事件为 malloc 副本，Dart listener 用
int         CtUpdateConfig(CtCore*, const char* config_json);
int         CtShareCreate(CtCore*, const char* paths_json, const char* options_json, const char** out_share_id);
int         CtShareClose(CtCore*, const char* share_id);
int         CtReceiveStart(CtCore*, const char* code_or_link, const char* save_dir, const char** out_transfer_id);
int         CtReceiveResume(CtCore*, const char* transfer_id);
int         CtTransferPause / CtTransferResume / CtTransferCancel(CtCore*, const char* transfer_id);
const char* CtQuery(CtCore*, const char* query_json);   // 快照：shares / receives / transfers / config
void        CtFreeString(const char*);
const char* CtVersion(void);
```

（实际实现见 `core/include/crosstransfer/ct_api.h`；函数名按项目约定用大驼峰。）

事件：`signal_state`；`share_state`（creating / ready / claimed / transferring / completed / closed / failed，含 code、link、expires_at、接收端计数）；`receive_state`（claiming / connecting / waiting_offer / transferring / verifying / completed / failed，含 `code_not_found` / `code_expired` / `share_busy`）；`transfer_progress`（bytes、rate、eta、当前文件、P2P / TURN / 中继）；`error`。

## 八、Flutter 应用

桌面视觉（2026-09-23）：Windows / macOS / Linux 使用独立桌面主题和唯一的 360 × 420 固定窗口（含系统标题栏，不允许拖动缩放或最大化）。启动、托盘和链接唤起同一窗口，不再区分主窗口与投递篮；标题栏、窗口按钮与拖动使用操作系统原生装饰，底部状态栏保留连接状态和置顶。发送 / 接收 / 设置在窗口内切换并保留页面状态，支持 ⌘/Ctrl + 1/2/3 切页、⌘/Ctrl + , 打开设置。macOS 使用中性分段导航，Windows / Linux 使用下划线选中导航；按钮、输入框与菜单采用桌面密度、小圆角和键盘焦点反馈，无水波纹或移动端页面滑入动画。发送默认直接拖放或选文件，取件码与复制操作单列排列；发送记录保留二维码、进度和关闭分享等功能。接收与设置省略大标题并按需滚动。系统无衬线字体、中性表面、蓝色主操作、细分隔线覆盖中英文、深浅色和放大文字。macOS 以 AppKit NSVisualEffectView 提供窗口背景毛玻璃，Flutter 底层透明，内容卡片使用半透明底色；输入框和浮层保持清晰可读，系统开启“减少透明度”时回退为不透明背景。在固定窗口内展开完整路径并允许换行，长列表继续滚动。首次启动默认不置顶，继承原有窗口位置与置顶偏好。移动端继续使用原有主题，不分发 Apple 字体或引入新的 UI 依赖。

macOS 原生菜单：启用应用菜单中的“设置…”（⌘,），View 菜单增加发送 / 接收 / 设置（⌘1/2/3），通过 MethodChannel 切回主页面；菜单标签随应用语言更新，保留 AppKit 原生 Edit / Window / Services 菜单。布局回归按系统标题栏预留 38 px，覆盖桌面三平台主题、中英文、深浅色与 1.5 倍文字。

桌面交互优化（2026-09-23）：取件码结果页直接显示当前分享各接收端的进度、速度与剩余时间，单独取消某次发送不关闭整个分享；没有进行中传输时保留最近一次结果反馈，无须进入记录查看。结果页同时显示取件码剩余有效期，复制取件码为主操作，复制链接与二维码为次级入口；复制反馈在按钮原位显示 2 秒。二维码使用独立弹窗，分享结束或过期即隐藏二维码，过期不打断已建立的传输。桌面接收页固定输入区，仅接收记录独立滚动；保存位置收成可点击的单行目录名，悬停显示完整路径。导航显示进行中的发送 / 接收数量，底栏显示总数，发送记录入口同步显示进行中数量；按实际收发任务计数，接收记录与底层传输不重复累计，等待领取的分享及已暂停 / 中断 / 完成 / 失败任务不计入。

依赖：`ffi`、`ffigen`、`flutter_riverpod`、`path_provider`、`file_picker`、`desktop_drop`、`qr_flutter`、`app_links`、`tray_manager` + `window_manager`、`flutter_local_notifications`、`open_filex`（BSD / MIT）。扫码通过平台桥接：iOS 使用系统 AVFoundation，Android 使用 ZXing Android Embedded 4.3.0（Apache-2.0）。阶段 5 移除 `mobile_scanner`，其 Android 传递依赖 ML Kit 受额外 Google API 条款约束，不符合本项目已选定的依赖许可证范围。相机授权、取消、前后台生命周期由原生扫描界面管理，Dart 统一校验取件码并展示错误/重试。

页面：

1. **发送页**：拖入 / 选择文件或目录 → 二维码 + "复制链接 / 系统分享"为主视觉，取件码次要展示 → 等待 / 进度 / 完成 / 关闭分享。
2. **接收页**：桌面端输入取件码 / 粘贴分享链接；移动端保留扫码 / 粘贴链接及手输 10 位码 → 保存目录 → 清单与进度 → 完成后打开目录。
3. **设置**：保存目录、分享 ttl、默认 once / open、语言（中 / 英）；桌面使用“常规 / 分享”两组紧凑列表行，标签在左、当前值在右，语言与模式通过菜单选择，目录显示完整路径并允许换行；分组标题使用 11 号半粗体，选项、当前值与菜单统一 12 号常规字重，单位使用 11 号辅助文字，并保留系统文字缩放；桌面有效期提供 5 分钟 / 10 分钟 / 30 分钟 / 1 小时 / 自定义，自定义仍使用秒并校验 30–86400 秒。桌面语言、目录、分享模式和有效期统一编辑后保存，取消恢复已保存值；仅有未保存修改时显示固定在底部的取消 / 保存操作，保存错误在操作区内显示，避免浮动提示遮挡重试按钮。底部用单行“关于 + 版本”入口进入独立页面，展示版本、版权与第三方开源声明入口。

平台：桌面托盘与关窗隐藏；Windows / macOS / Linux 共用可由托盘呼出的唯一紧凑窗口，窗口置顶状态与位置可保留，拖入文件或目录后直接走现有分享状态机，macOS 菜单栏图标拖放只作为可选平台增强而非跨平台基线；iOS 15.0+，原生分享扩展 + App Group 批次导入、`Documents/Received`、传输期间 `beginBackgroundTask`；Android SAF、分享入口、前台服务。iOS 分享扩展导入后提示用户返回主 App 生成取件码，不采用 `share_handler` 的响应链 UIApplication 跳转；Android 分享插件在阶段 4 决定。

桌面基线（阶段 2 确定）：macOS 12.0+（Flutter 3.47 模板与 `file_picker_darwin` 的要求），**不启用 App Sandbox**（P2P 任意 UDP 端口 + 用户任意目录读写），走 Developer ID 签名 + 公证的 dmg 分发；`crosstransfer_native` 以 `vendored_libraries` podspec 嵌入 `Contents/Frameworks/`。Windows / Linux 把共享库放在可执行文件旁（`lib/`），Dart `DynamicLibrary.open` 按 `CT_NATIVE_LIB` → 包内路径 → 裸名顺序查找。

## 九、构建与部署

- 根 `xmake.lua`：`includes("minirtc")`，`crosstransfer_core`（static）、`ct_cli`（binary）、`crosstransfer_native`（shared umbrella，`-force_load` / `--whole-archive`）。
- 桌面：`tools/build_native.sh <plat> <arch>` → `app/<plat>/native/libcrosstransfer_native.*`，Dart `DynamicLibrary.open`。
- iOS：将 core / MiniRTC / 静态依赖合并为 `.a`，device arm64 与 simulator arm64/x86_64 包装为静态 XCFramework，通过 podspec `vendored_frameworks` 集成并保留 FFI 导出，Dart `DynamicLibrary.process()`。
- Android：xmake/NDK 构建三 ABI 共享库到 `jniLibs`，Gradle 构建任务验证产物并打包。NDK r28+，ELF 与 APK 按 16 KB 页面要求对齐；Android 7.0 / API 24 起。
- 服务端：`go build` 单二进制；`Dockerfile`（distroless）、`compose.yaml`（信令 + 内嵌 TURN，主机网络）；配置 `CT_LISTEN`、`CT_TLS_CERT/KEY` 或 `CT_ACME_DOMAIN`、`CT_PUBLIC_IP`、`CT_TURN_PORT`、`CT_TURN_PORT_RANGE`、`CT_TURN_SECRET`、`CT_EXTERNAL_TURN`、`CT_RELAY_RATE_LIMIT`。
- CI：native 三平台 + iOS 未签名；`go test` + `go vet` + 多架构镜像；`flutter build`；发布门禁包含第三方许可证清单生成与依赖许可证核对。

## 十、实施阶段

**阶段 0：服务端 + 特化版 MiniRTC**
1. `server/`：信令、取件码、TURN 凭据、内嵌 TURN、WSS 中继、健康检查；`go test` 覆盖协议状态机、取件码分配 / 过期 / 限速、中继转发；本地可跑。
2. `minirtc/`：删除媒体、浏览器路径与 libnice / glib / gupnp；`ice_agent` 改为 libjuice + miniupnpc；重写 `pc/` 信令客户端、`ice_transport_controller` 数据专用版、SDP；新 C API；四平台编译；`examples/data_echo` 经本地 server 跑通 P2P、强制 TURN 与 WSS 中继。
3. 数据路径改造：非可靠流接 pacer + BWE，暴露链路估计；KCP 参数可配；限速 / 丢包网络下实测。

**阶段 1：core + ct_cli**
4. xmake 骨架、日志、Peer 封装、事件循环、Share / Receive 状态机、取件码与链接编解码。
5. ctrl / 块 / sack 编解码、Sweep/Repair 发送器、位图接收器、SHA-256、续传；单元测试。
6. `ct_cli share` / `ct_cli receive` 两进程经本地 server 端到端。

**阶段 2：桌面 Flutter**（macOS → Windows → Linux；2026-09-22 工程验收完成，记录见 `docs/PHASE2_NOTES.md`）
7. 安装 Flutter、`flutter create`、ffigen、`CoreClient` 与 providers。
8. 三个页面、拖拽、二维码、链接 scheme、托盘、通知。
9. 三平台 native 集成与打包（dmg / pkg、NSIS、deb）。

**阶段 3：iOS**（2026-09-22 主要实现与本机验收完成；真机/域名验收待补，见 `docs/PHASE3_NOTES.md`、`docs/IOS_BUILD.md`）
10. 静态库合并 + podspec；分享扩展；扫码；Universal Link；`Documents/Received`；后台任务。

**阶段 4：Android**（2026-09-22 主要实现、本机自动化及完整 CI 验收完成；真机/正式签名/域名验收待补，见 `docs/PHASE4_NOTES.md`）
11. 特化版 MiniRTC 补 android 平台 xmake 配方与 NDK 构建（libjuice / OpenSSL / libsrtp 交叉编译）。
12. Runner：`jniLibs`、SAF、分享入口、App Link、前台服务。

阶段 4 实施约定：arm64-v8a / armeabi-v7a / x86_64；SAF 选文件/目录与外部分享均先导入 App 私有持久目录，core 始终使用有效 POSIX 路径。接收到私有 Received 后由用户通过 SAF 导出，避免把 `content://` 当作文件路径。FlutterEngine 由 Application 持有，Activity 重建不销毁传输引擎；活动收发使用 dataSync 前台服务及通知，系统超时停止服务并请求暂停。App Link 的域名和正式签名证书关联待所有者提供，先验收 scheme 和本地签名测试包。

**阶段 5：加固与公共服务**（2026-09-22 主要工程加固、CI 全矩阵及关闭兼容回退的 Android 16 KB 模拟器运行验收完成；正式签名、域名/公网与真机验收仍待资源，见 `docs/PHASE5_NOTES.md`）
13. CI 全矩阵、多接收端并发、强制 TURN、WSS 中继压测、TLS / ACME、文档、第三方许可证清单、App 内第三方开源声明页。
14. 可选：SPAKE2 口令认证、浏览器接收页、libjuice 之上的打洞增强（对称 NAT 预测、中继后升级 P2P）。

阶段 5 首批加固：原生 OpenSSL 固定到仍在维护的 3.5 LTS（当前 3.5.8），Windows 默认使用 nmake 并保留依赖构建失败日志；WSS 必须同时验证受信证书链与目标 DNS/IP 的 SAN，拒绝不匹配、过期及不受信证书，并以回归测试覆盖；梳理所有传递依赖许可（尤其移动端扫码 SDK），完善 App 内许可页面与分发清单；对移动端导入副本提供可控清理。公开域名、证书和真实设备验证仍按所有者提供的资源推进。

通知依赖整改：`flutter_local_notifications` 的 Android 实现依赖 `desugar_jdk_libs`（GPL-2.0 with Classpath Exception），虽有链接例外，仍不符合本项目不引入 GPL/LGPL 的约束。移除该聚合插件与 desugaring 运行库；Android 使用 NotificationManager，iOS/macOS 使用系统 UserNotifications，仅保留已使用的 Linux/Windows BSD-3-Clause 平台插件。即时收发通知行为不变，不引入定时通知需求；Android 最低 API 24 保持不变。

导入副本清理：设置页显示 Imported 的占用和可清理批次，用户确认后只删除本次预览列出的 UUID 批次；进行中/暂停的发送、未处理 Inbox 和正在导入的文件必须保留。清理期间禁止新建/恢复发送，原生文件操作串行化并在删除前重新检查 Inbox。不得遍历符号链接或删除 Received、用户源文件及任意传入路径。

自托管加固：落地页仅渲染规范化的有效取件码，配置 `CT_DOWNLOAD_URL` 后提供 HTTPS 下载跳转；`CT_ASSOCIATION_DIR` 可提供两个固定的 App/Universal Link 关联 JSON 文件。健康探测读取与服务相同的 YAML/环境配置并在 ACME 模式使用域名 SNI；容器为非 root 用户准备持久证书目录。域名关联内容由签名/域名配置工具生成，部署不自动推断正式身份。

内嵌 TURN peer 策略：默认仅允许公共 IPv4 单播目标，拒绝私网、回环、共享地址、链路本地、组播、文档/基准测试及保留地址，避免中继到服务器内部网络。`CT_TURN_ALLOW_PRIVATE_PEERS=true` 仅供受控私网/回环测试，显式放行 RFC1918、回环和 CGNAT；链路本地、组播等仍拒绝。当前内嵌中继仅有 UDP4，不接受 IPv6 peer。外部 TURN 的策略由运营者独立配置，带宽/资源配额另行加固。

并发 TURN 加固：libjuice 接收回调持有内部连接锁，而 TURN 发送也需要该锁；不得在此回调中进入持有发送/反馈/DTLS 锁的传输代码。ICE 封装将收包复制到每 agent 的有界队列（最多 4 MiB、4096 包），由独立线程按序交付，满时按 UDP 丢包处理。关闭时先禁用新发送/收包并停止 libjuice，再清空队列、等待交付线程退出；应用结束后不得残留回调。

强制 TURN 不能仅过滤发出的候选：libjuice 1.7.2 仍可通过 peer-reflexive 检查发现并选中直连。为 `juice_config` 增加可选 `relay_only`，在底层配对时拒绝所有非本地 relay 候选；只有强制 TURN 开启，自动/P2P 保持默认行为。补丁和完整对应 libjuice 源码继续按 MPL-2.0 提供，随二进制分发其许可、修改说明和源码归档；不改变本项目其他源文件的专有许可。

macOS Release 临时构建约定：Flutter 3.47.5 触发上游 #191575 的内部 FFI class ID AOT 崩溃；构建脚本在仓库 build 目录中复制 SDK，校验精确版本/源文件后仅为 6 个内部 FFI 类型添加 entry-point 保留标记。不得改动全局 SDK、关闭验证或启用实验窗口特性；升级 SDK 时复核并移除处理。

公共服务配额约定：信令默认最多 1024 个连接、每 IP 32 个连接，升级 WebSocket 前拒绝超额请求并在断开/升级失败后释放名额；每连接仍最多 16 个分享。会话默认全局 4096、每 peer 64（含发送端保留的离线续传会话），达到上限返回 `server_busy`，不得消费 once 码，既有会话可按 token 恢复。WSS 每连接发送队列同时限制 512 帧和 4 MiB；默认中继有效载荷上限每连接 8 MiB/s、全局 64 MiB/s，超额帧按不可靠传输丢弃。内嵌 TURN 默认最多 512 个实际 relay socket，每 allocation 8 MiB/s、全局 64 MiB/s，收/发合并计数；限额和丢弃指标可观测，关闭/失败必须回收名额。连接/会话/分配上限为正数；带宽设为 0 可供运营者显式关闭。外部 TURN 仍由运营者在对应服务独立配置。

## 十一、验证

- **server**：`go test`（协议状态机、取件码分配 / 过期 / 限速、TURN 凭据、中继转发）；两个 WebSocket 客户端脚本走完 create_share → claim → signal → relay → leave。
- **minirtc**：四平台编译；依赖清单与许可证核对（无 LGPL）；`data_echo` P2P / 强制 TURN / WSS 中继 / SRTP 收发、断线重连。
- **core**：编解码往返与畸形输入、位图 / 游程、路径清洗、Sweep/Repair 状态机、取件码 / 链接解析。
- **ct_cli 端到端**：0 字节、< 1 块、≥ 1 GiB（内存平稳、吞吐记录）、含子目录、同名、非 ASCII、kill 接收端后凭 `resume_token` 续传、`TurnForceUdp`、中继模式、错误 / 过期码、`open` 模式两接收端并发、5% 丢包下完整性。
- **Flutter 与 iOS 真机**：全流程、扫码、链接直达、分享菜单。

## 十二、风险

- 特化版 MiniRTC 的 `pc/`、`ice_agent`、`ice_transport_controller` 属于重写而非裁剪，四平台（含 iOS）编译要在阶段 0 内完成。
- libjuice 替换 libnice 会丢失现有打洞补丁，P2P 成功率可能略降；以 TURN-UDP + WSS 中继保证连通性，成功率数据在阶段 0 的 `data_echo` 实测中记录。
- UDP 完全封锁的网络只能走 WSS 中继，吞吐受服务端带宽限制；中继限速与计费策略在阶段 5 定。
- 自研块协议的速率控制依赖 BWE 接入效果，阶段 0 第 3 步需在限速 / 丢包网络实测；不理想则退回 SACK 丢包率 AIMD。
- 内嵌 `pion/turn` 成熟度低于 coturn；凭据算法与 coturn 兼容，可随时切换。
- iOS 后台传输受限，大文件需前台。
- Android 依赖 MiniRTC NDK 移植，工期不确定。
