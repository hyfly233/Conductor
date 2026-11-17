# Conductor 技术架构文档

## 1. 架构目标

Conductor 是 macOS 上的 sing-box 控制器。它负责生命周期、配置和可视化状态；sing-box 负责 TUN、DNS、VLESS Reality 和路由执行。

```text
SwiftUI 菜单栏应用
        ├── 配置页
        ├── 公司 VPN 页
        ├── 设置页
        └── 日志页
        ↓
应用服务层
        ├── SingBoxProcessManager
        ├── ConfigValidator
        ├── LogStore
        ├── ProxyEndpointStore
        ├── RouteRuleStore
        ├── VLESSURIParser
        ├── AppBindingStore
        ├── CompanyVPNInspector
        ├── ConfigurationHistoryStore
        └── RuntimeStatus
        ↓
Conductor.app 内置 sing-box 1.14.0
        ├── TUN
        ├── DNS
        ├── VLESS Reality
        ├── SOCKS5/HTTP 出站与混合端口探测
        └── 路由规则
        ↓
macOS 网络栈
        ├── en0：普通直连
        ├── OpenVPN utun：公司网段
        ├── EasyConnect utun：公司网段
        └── aTrust utun：公司网段
```

## 2. 模块划分

### 2.1 SwiftUI 层

职责：

- 菜单栏入口
- 状态展示
- 启停按钮
- 配置和日志入口
- 错误提示
- 四页控制面板导航
- 跨页面固定运行状态与启停入口

不直接处理网络数据包，不实现 VLESS 或 DNS 转发。

### 2.2 应用服务层

建议的职责对象：

```text
AppState
  管理界面可观察状态

SingBoxProcessManager
  启动、停止、监控 sing-box

ConfigValidator
  校验内置运行时版本并执行 sing-box check

SingBoxRuntimeProvider
  定位内置二进制并校验版本、架构和可执行权限

LogStore
  接收 stdout/stderr，保存最近日志

ConfigurationStore
  读取配置路径和非敏感应用设置

CompanyVPNInspector
  读取 utun 接口、系统路由和公司网段的实际去向

ConfigurationHistoryStore
  保存备份元数据、检查历史并执行安全恢复
```

首期可以使用 Swift Concurrency 和 `Process` 实现，暂不引入第三方依赖。

### 2.3 sing-box

Conductor 1.0 内置 sing-box 1.14.0 作为发布基线，并将其作为子进程运行：

```bash
Conductor.app/Contents/Resources/bin/sing-box check -c <config>
sudo Conductor.app/Contents/Resources/bin/sing-box run -c <config>
```

正式发布构建只解析应用包内路径：

```text
Conductor.app/Contents/Resources/bin/sing-box
```

Apple Silicon 和 Intel 发布物分别包含对应架构的 sing-box 1.14.0。应用启动前执行 `sing-box version` 并校验版本不低于 1.14.0；配置检查和正式运行必须复用已校验的同一个 URL。

Debug 构建可通过显式开发设置使用 `/opt/homebrew/bin/sing-box` 或 `/usr/local/bin/sing-box`，但该能力不进入正式发布默认路径，也不能在内置运行时失效时静默回退。

### 2.4 SOCKS5/HTTP 与混合端口代理出口

本机或远端的 SOCKS5/HTTP 代理被建模为 sing-box outbound：

```json
{
  "type": "socks",
  "tag": "vpn-proxy-01",
  "server": "127.0.0.1",
  "server_port": 10801
}
```

HTTP 端口使用 `type: "http"`。Conductor 保存端点、检查端口、生成配置和展示状态；VPN 工具负责自身登录、连接和重连。

sing-box 没有用于连接上游的 `mixed` outbound。“混合端口”只存在于 Conductor 的输入模型中，对同一端点分别执行 HTTP CONNECT、SOCKS5 CONNECT 和 SOCKS5 UDP ASSOCIATE 握手探测，然后生成具体的 `http` 或 `socks` outbound。SOCKS5 CONNECT 成功时优先 SOCKS5，否则使用已验证的 HTTP；两者均失败则拒绝保存。当前结果只包含协议探测布尔值，不记录时间或细分失败原因；UDP 握手成功不保证数据转发成功。

### 2.5 VLESS URI 导入

配置表单更新已有 HTTP/SOCKS5 outbound 时合并受管字段，保留未编辑的高级参数；按所选范围替换对应的简单域名、IP 或应用路径规则，保留其他范围及组合条件规则。删除出口仍按删除语义清理绑定。构建通过不代表真实 TUN 网络回归通过，验证记录见操作验收记录。

`VLESSURIParser` 将用户粘贴的 URI 转换为内部节点模型。MVP 支持 VLESS Reality，解析 UUID、服务器、端口、flow、SNI、uTLS 指纹、Reality 公钥和 short ID。`AppBindingStore` 负责把节点绑定到 ChatGPT 进程和域名规则。

### 2.6 展示模型边界

界面中的对象分为三类，不共用同一个“VPN 配置”模型：

| 展示对象 | 数据模型 | 是否为 sing-box outbound |
| --- | --- | --- |
| VLESS 节点 | `ProxyNode` | 是 |
| 本地 SOCKS5/HTTP/混合端口工具 | `ProxyEndpoint` + `ProxyProtocolProbeResult` | 是；混合模式最终生成具体协议 |
| OpenVPN/EasyConnect/aTrust | `CompanyVPNObservation` | 否 |

`CompanyVPNObservation` 是一次检测快照，当前保存进程检测结果、目标网段的路由输出、候选接口和检测时间；尚不采集 DNS 证据。它不负责控制公司客户端，也不把易变化的 `utun` 编号作为永久身份。

## 3. 网络数据路径

### 3.1 代理流量

```text
ChatGPT 应用
  ↓
sing-box TUN
  ↓
process_path / process_name 规则
  ↓
VLESS + Reality + Vision
  ↓
VPS Xray 服务端
```

### 3.2 公司流量

```text
公司内网连接
  ↓
TUN 排除网段
  ↓
macOS 系统路由
  ↓
OpenVPN / EasyConnect / aTrust 对应 utun
```

公司 VPN 不作为 sing-box outbound 使用。因为这些客户端没有提供 SOCKS5/HTTP 入口，Conductor 不尝试伪造代理出口。

### 3.3 本地代理端口流量

```text
指定应用或域名
  ↓
sing-box TUN
  ↓
规则匹配
  ↓
vpn-proxy-* SOCKS5/HTTP 本地端口
  ↓
端口型 VPN 工具
```

本地端口不可用时，记录失败并提示用户。MVP 不自动降级到其他出口。

本地代理表单使用 `127.0.0.1:7890` 作为端点初始值。以下仅为用户保留默认名称时的生成示例：

```json
{
  "type": "socks",
  "tag": "vpn-proxy-01",
  "server": "127.0.0.1",
  "server_port": 7890
}
```

选择“剩余流量”时，将 `route.final` 设置为用户填写的出口 tag。显式的 ChatGPT VLESS、公司 CIDR、DNS 劫持和其他路由规则必须位于默认出口之前。协议可以由用户明确选择 SOCKS5/HTTP，也可以选择混合端口后进行应用层探测；不能仅凭 7890 端口号推断协议或 VPN 产品。混合端口最终仍写入具体的 `type: "socks"` 或 `type: "http"`。

当最终协议仅支持 TCP 且该出口是 `route.final` 时，在显式 VLESS、公司网段和 VPN 客户端防回环规则之后、默认出口之前加入 UDP/443 快速拒绝规则：

```json
{
  "network": "udp",
  "port": 443,
  "action": "reject"
}
```

该规则用于让支持 QUIC 的浏览器立即回退 TCP，不把 UDP 数据包交给 HTTP outbound。它不表示所有 UDP 都被代理；其他 UDP 保持显式规则优先，否则按产品配置处理。生成规则后仍必须通过内置 sing-box 1.14.0 的 `check`。

对于本机 VPN 应用，用户选择 `.app` 后枚举其包内父目录名为 `MacOS` 的可执行文件。分别生成 `process_path` 和 `process_name` 的 `direct` 规则，并插入路由规则最前部：

```json
{
  "process_path": [
    "/Applications/FastLink_Lite.app/Contents/MacOS/FastLinkCore"
  ],
  "action": "route",
  "outbound": "direct"
}
```

该规则使 FastLinkCore 的上游连接绕过 `route.final`，从而切断“FastLinkCore → sing-box TUN → 127.0.0.1:7890 → FastLinkCore”的回环。应用更新可能改变可执行路径，因此配置卡片需要保留排除来源，后续可重新选择应用刷新规则。

### 3.4 普通流量

```text
普通连接
  ↓
sing-box TUN
  ↓
final: direct
  ↓
en0 或系统路由
```

`direct` 由系统路由决定，必须通过测试确认它没有被某个公司 VPN 的默认路由接管。

### 3.5 应用绑定数据流

```text
VLESS URI + 目标应用 ChatGPT
  ↓
解析节点
  ↓
更新绑定节点 outbound
  ↓
生成 ChatGPT process_path / process_name 规则
  ↓
生成 ChatGPT/OpenAI domain_suffix 规则
  ↓
规则统一指向 chatgpt-vless
```

### 3.6 VLESS URI 导入数据流

```text
粘贴 vless:// URI
  ↓
URLComponents 解析与字段校验
  ↓
生成临时 sing-box JSON
  ↓
sing-box check
  ├─ 失败 → 删除临时文件，保留原配置
  └─ 成功 → 备份原配置并原子替换
```

## 4. 配置原则

### 4.1 TUN

- 不指定任意自定义接口名，让 sing-box 在 macOS 上自动创建 `utun`。
- 使用 `auto_route: true` 和 `strict_route: true`。
- 使用 `route_exclude_address` 排除公司网段。
- 公司网段来自实际 `netstat -rn -f inet`，不应凭经验填写。

### 4.2 出口生成

ConfigurationStore 根据用户设置和混合端口探测结果生成 VLESS outbound、每个具体 SOCKS5/HTTP outbound、公司网段排除地址、排序后的路由规则和默认 `direct` 出口。生成后必须执行 `sing-box check`，失败时保留上一份可用配置。

VLESS URI 导入沿用同一配置生成链路，使用固定 tag `chatgpt-vless` 更新已有出站；不存在时插入到出站列表前部。正式配置替换前创建带唯一后缀的备份文件。

应用绑定使用稳定标识 `chatgpt`，与节点 tag 分离，便于未来支持多个节点和多个应用。未匹配的流量继续按原有路由规则处理。

### 4.3 VLESS Reality

客户端需要：

- VPS 公网 IP
- 服务端端口
- UUID
- `xtls-rprx-vision`
- Reality 公钥
- short ID
- 服务端 `serverNames` 中的 SNI
- uTLS fingerprint

服务端私钥只保存在服务端，不能进入客户端配置或日志。

### 4.4 DNS

使用 sing-box 1.12+ 新 DNS server 格式：

```json
{
  "type": "https",
  "tag": "remote-dns",
  "server": "1.1.1.1",
  "path": "/dns-query",
  "detour": "chatgpt-vless"
}
```

需要配置 `route.default_domain_resolver`，避免旧版缺省解析行为。

公司内部域名应使用公司 DNS；如果公司 VPN 提供专用 DNS，应按公司域名配置 DNS 规则。不能假设公共 DNS 能解析公司内部域名。

## 5. 进程与域名规则

规则优先级建议：

1. sing-box 自身 VPS 地址直连，防止回环。
2. 公司网段排除或直连。
3. ChatGPT 进程路径和辅助进程 → VLESS。
4. ChatGPT/OpenAI 域名 → VLESS。
5. Google 等其他指定域名 → 根据实际需求选择出口。
6. 端口型 VPN 出口规则 → 对应 `vpn-proxy-*`。
7. `final` → 用户选择的剩余流量出口；未配置时为 `direct`。

macOS 应优先使用完整 `process_path`。ChatGPT 可能创建 Helper、Renderer 或 GPU 辅助进程，需要通过连接日志确认实际名称。

## 6. 进程管理与权限

MVP 采用 `Process` 管理 sing-box，并记录：

- PID
- 启动时间
- 配置路径
- 当前状态

TUN 通常需要管理员权限。权限方案分两期：

### MVP

Conductor 保持自身以普通用户运行。启动 TUN 时通过 macOS 的 `osascript` 管理员授权对话框，以 root 权限后台启动 sing-box；运行日志写入 `~/Library/Logs/Conductor/sing-box.log`，PID 写入同目录的状态文件，Conductor 通过 PID 和日志文件监控状态。停止时仅向该 PID 发送终止信号，并通过管理员授权执行。

### 完整版本

使用 macOS Privileged Helper Tool 或 Network Extension 体系，避免在 GUI 中处理明文 sudo 密码。该版本需要单独完成签名、授权和安装流程。

## 7. 进程状态机

```text
stopped
  ↓ start
validating
  ├─ invalid → configError
  └─ valid
       ↓
starting
  ├─ process exits → failed
  └─ process alive → running

running
  ↓ stop
stopping
  ├─ exits → stopped
  └─ timeout → failed
```

进程退出时读取最后一段 stderr，并将其展示给用户。应用不自动重启，除非后续需求明确开启该能力。

## 8. 配置和日志存储

建议路径：

```text
配置：~/sing-box/config.json
日志：~/Library/Logs/Conductor/sing-box.log
应用设置：~/Library/Preferences/com.hyfly.Conductor.plist
配置历史：~/Library/Application Support/Conductor/ConfigurationHistory/
```

配置文件由用户维护时，应用只保存路径和非敏感元数据。日志设置大小上限，避免长期运行无限增长。

配置历史目录保存备份文件和不含密钥的元数据：创建时间、变更来源、原配置摘要和 `sing-box check` 结果。恢复流程必须采用“检查候选版本 → 备份当前版本 → 原子替换”，不能直接覆盖。

### 8.1 控制面板状态结构

四个页面共享同一个 `AppState`，运行状态不能由当前页面自己的临时状态推断：

```text
AppState
├── runtimeStatus / privilegedPID
├── selectedSection
├── proxyConfigurations
├── companyVPNObservations
├── configurationHistory
└── logViewState
```

“检查配置”只更新检查结果；如果管理员 PID 仍存活，不得把总体状态从运行中改成未运行。

界面层建议拆分为以下 SwiftUI 组件，组件只发送意图，不直接读写 sing-box JSON：

```text
ControlWindow
├── SectionPicker
├── ConfigurationPage
│   ├── ProxyConfigurationCard
│   └── ConfigurationEditorSheet
├── CompanyVPNPage
│   ├── CompanyVPNCard
│   └── RouteEvidenceSheet
├── SettingsPage
│   ├── RuntimeSection
│   └── ConfigurationHistorySection
├── LogsPage
│   ├── LogToolbar
│   └── LogList
└── RuntimeStatusBar
```

`RuntimeStatusBar` 只订阅共享 `RuntimeStatus`。页面切换、配置检查或日志筛选不得直接写总体运行状态。

页面状态使用稳定枚举：

```text
ControlSection = configuration | companyVPN | settings | logs
HealthState = unknown | checking | healthy | warning | failed
CompanyVPNState = disconnected | connected | uncertain | failed
```

代理配置中的 `enabled` 与 `healthState` 分开存储，避免把“未测试”误判成“已停用”。

#### 8.1.1 写操作门禁

所有会改变 sing-box 配置的操作统一经过 `ConfigurationMutationGate`：

```text
用户操作
  ↓
检查 RuntimeStatus
  ├─ running/starting/stopping → 拒绝并提示先停止代理
  └─ stopped
       ↓
生成候选配置 → check → 备份 → 原子替换 → 刷新界面模型
```

测试节点、读取路由、查看历史和筛选日志属于只读操作，代理运行时仍可执行。

### 8.2 公司 VPN 检测

当前公司 VPN 检查通过进程匹配和对预设网段的路由查询提供只读证据；不采集 DNS resolver，也不确认客户端与 `utun` 的归属。实际连接和接口归属保持未知，需要用户结合客户端和系统路由核对。

添加公司网段后，`ConfigurationStore` 更新 TUN 排除地址并执行配置检查。检测功能不执行公司 VPN 的启动、停止、登录或路由修改。

### 8.3 运行时完整性

构建阶段将 sing-box 1.14.0 放入 `Conductor.app/Contents/Resources/bin/`，保留上游许可证和版权说明。发布流水线验证二进制版本、目标架构和 SHA-256，再对完整应用执行代码签名、公证和 stapling。

运行时检查顺序：

```text
定位 Bundle.main 内置路径
  ↓
检查文件存在和可执行权限
  ↓
执行 sing-box version
  ↓
版本不低于 1.14.0（仅接受纯数字与点号）
  ├─ 失败 → 禁止 check/run，提示重新安装或升级
  └─ 成功 → 缓存本次运行使用的 URL
```

管理员授权命令只能引用已校验的内置绝对路径。不得根据 `PATH` 查找 sing-box，以免 root 环境运行到另一个版本。

### 8.4 Homebrew Cask 发布

使用自有 Tap 仓库 `hyfly233/homebrew-conductor`，Cask token 为 `conductor`。用户安装入口：

```bash
brew install --cask hyfly233/conductor/conductor
```

Cask 按 CPU 架构选择已签名、公证的固定版本发布物，校验 SHA-256 后将 `Conductor.app` 安装到 `/Applications`。Cask 不声明 Homebrew Core `sing-box` Formula 依赖，因为它是滚动版本且无法保证与 Conductor 的配置兼容基线一致。

发布结构建议：

```text
GitHub Release / v1.0.0
├── Conductor-1.0.0-arm64.zip
├── Conductor-1.0.0-x86_64.zip
├── SHA256SUMS
└── release notes

hyfly233/homebrew-conductor
└── Casks/conductor.rb
```

升级仅替换 `/Applications/Conductor.app`。用户数据位于 Home 目录，不放进 App Bundle；Cask 的普通卸载不删除配置和历史。只有显式执行带 zap 的清理操作时，才按 Cask 中公开列出的路径清理应用偏好和缓存，默认不删除 `~/sing-box`。

## 9. 验证方案

### 静态验证

```bash
Conductor.app/Contents/Resources/bin/sing-box version
Conductor.app/Contents/Resources/bin/sing-box check -c ~/sing-box/config.json
```

### 运行验证

```bash
ifconfig | grep -E '^utun|status'
netstat -rn -f inet | grep '^default'
route -n get <公司内网IP>
```

### 分流验证

- ChatGPT 日志包含 `outbound/chatgpt-vless`。
- 公司内网路由仍指向 OpenVPN、EasyConnect 或 aTrust 的 `utun`。
- 普通国内站点日志包含 `outbound/direct`。
- VLESS 服务端 IP 不被送回 TUN，避免回环。
- 指定流量的日志出口与预期端口型 VPN 一致。
- 混合端口探测的 HTTP/SOCKS5 结果与最终生成的 outbound 类型一致。
- 仅 TCP 的默认代理出口不会出现持续的 `UDP is not supported by outbound`，UDP/443 被快速拒绝后浏览器改用 TCP。
- VLESS URI 导入后，`sing-box check` 成功且原配置仍可从备份恢复。
- 切换控制面板页面以及执行配置检查时，管理员 PID 存活则运行状态保持一致。
- 公司 VPN 检测展示当前路由证据，无法确认接口归属时不生成虚假的客户端绑定。
- 历史配置恢复失败时，当前正式配置内容和权限保持不变。
- 未安装独立 sing-box Formula 的干净机器仍可启动 Conductor。
- 配置检查与管理员启动日志中的版本和路径均指向内置 sing-box 1.14.0。
- arm64 和 x86_64 Cask 发布物通过 SHA-256、签名、公证和安装测试。
- Cask 升级应用后，`~/sing-box`、配置历史和偏好设置保持不变。

## 10. 已知限制

2026-11-03 验证环境：当前 Debug 构建未包含 `Resources/bin/sing-box`，本机 Homebrew 链接指向 1.14.3，与项目固定 1.14.0 的要求不一致。尚不能据此声明固定运行时与端到端启动验证完成。操作逻辑回归使用 `scripts/OperationChecks.swift`，其中配置变更测试明确使用成功/失败命令替身，只证明原文件保护、备份和规则变更语义。

- 没有 SOCKS5/HTTP 入口的公司 VPN 不能被 sing-box 作为普通 outbound 调用。
- 本地代理端口型 VPN 只有在端口可连接且协议兼容时才能使用。
- 混合端口探测只能证明探测时的协议能力；VPN 客户端重连或升级后能力可能变化，需要重新测试。
- URI 导入当前只支持 VLESS Reality；其他传输方式需要扩展解析模型。
- 多个 macOS VPN 网络扩展的路由优先级由系统和客户端共同决定。
- `DIRECT` 只表示 sing-box 不使用代理节点，不保证绕过系统 VPN。
- IPv6、QUIC 和应用辅助进程可能需要额外规则。
- 运行时最低版本为 1.14.0；更高版本可以运行，但升级仍可能带来配置迁移，必须重新执行 `check` 与回归。
- 正式版不回退到系统 PATH 中的 sing-box，因此内置运行时损坏时代理不可启动。

## 11. 实施顺序

1. 保留现有 sing-box 生命周期、VLESS 导入和管理员 PID 状态逻辑，并为界面重构补充回归检查。
2. 建立共享 `AppState` 和四页导航骨架，保证启停状态跨页面一致。
3. 将现有 VLESS 与 SOCKS5/HTTP 表单重构为配置卡片、测试和编辑流程，并增加混合端口协议及 UDP 能力探测。
4. 实现只读 `CompanyVPNInspector`，再实现公司网段的校验和配置写入。
5. 实现配置历史元数据、安全恢复和日志筛选展示。
6. 将 sing-box 1.14.0 纳入应用资源，完成版本校验、签名、公证和双架构发布物。
7. 创建 Homebrew Tap 和 Cask，验证安装、升级、卸载及用户数据保留。
8. 在真实环境验证 OpenVPN、EasyConnect、aTrust 与 sing-box TUN 共存，再决定接口识别和公司 DNS 的补充策略。
