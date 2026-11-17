# 操作优化验收记录

日期：2026-11-03。目标：让 Conductor 的配置、检查、编辑、删除和恢复操作更易理解、可恢复且不误改现有设置。整体尚未完成验收。

## 当前证据

| 流程 | 当前实现与验证 | 尚缺证据 |
| --- | --- | --- |
| 新增出口 | 单一端点输入、格式提示；地址边界逻辑检查通过 | 真实表单点击 |
| 编辑出口 | 回填地址、简单域名、范围、受管进程；保留认证和高级绑定；临时配置回归通过 | 真实编辑保存流程 |
| 混合端口 | 后台并行 HTTP/SOCKS5 探测，SOCKS5 优先；协议选择组合检查通过 | 真实代理握手及端到端 UDP |
| 删除出口 | 确认框、运行中禁用、清理绑定、备份；临时配置回归通过 | 真实确认框操作 |
| 失败保护 | 校验失败保留正式文件，无成功提示和额外备份；回归通过 | 固定版本真实校验失败 |
| 状态反馈 | 磁盘出口摘要、短暂结果提示、独立读取错误、刷新入口 | 真实窗口与运行态对照 |
| 窗口入口 | 菜单命令与 Command-0，默认 900×640 | 真实快捷键及最小尺寸布局 |
| 运行时 | Debug 支持选择固定版本；版本失败不再继续配置检查 | 1.14.0 二进制及正式内置运行时 |

VLESS 导入回归使用合成节点和真实 1.14.0 `check`：重复参数被拒绝、原配置不变；有效节点生成 ChatGPT 进程和域名绑定，保留公司网段与其他出口的直连规则，并创建备份。导入期间校验原文件是否被外部修改，敏感临时文件和备份使用 `0600`。这些检查未连接合成节点，也不证明 ChatGPT 在线可用。

## 可重复检查

固定版本真实配置检查已通过：官方 macOS arm64 归档 SHA-256 为 `a150c94012ff768b7261939cd236b9c8554127f45137230295d23a5660225cc9`，下载文件匹配；解压二进制报告 `sing-box version 1.14.0`。使用 `CONDUCTOR_CHECK_RUNTIME=/tmp/conductor-runtime-1.14.0/sing-box-1.14.0-darwin-arm64/sing-box /tmp/conductor-operation-checks` 验证 HTTP 默认出口、UDP/443 reject、删除后的配置均通过真实 `check`。此过程只修改临时测试配置，没有启动 TUN 或更改正式配置。正式 App 内置运行时、实际 TCP/UDP 转发仍未验收。

恢复工作后已重新运行上述固定版本回归，版本与全部现有断言再次通过；临时目录并非正式安装位置，不能替代发布包验收。

```sh
swiftc -module-cache-path /tmp/conductor-check-module-cache -parse-as-library Conductor/ConductorModels.swift Conductor/ConductorController.swift scripts/OperationChecks.swift -o /tmp/conductor-operation-checks
/tmp/conductor-operation-checks
git diff --check
```

变更测试使用临时目录与 `/usr/bin/true`、`/usr/bin/false` 代替校验器，不接管网络，不修改正式代理配置。通过这些检查不代表 sing-box 配置语法或真实网络通过。

## 后续验收顺序

1. 恢复桌面工具访问调试窗口，验证菜单入口、四页导航、编辑回填、错误提示、忙碌时禁用及取消行为。
2. 配套 sing-box 1.14.0；当前 Debug 包没有内置二进制，Homebrew 链接指向 1.14.3，不满足固定版本要求。
3. 用隔离临时配置验证真实 `check`、保存、删除和恢复，确认原文件与备份权限。
4. 验证真实混合代理的 TCP 和 UDP 数据往返；UDP ASSOCIATE 成功只能证明握手被接受，界面不能据此承诺完整 UDP 可用。
5. 在用户现有公司 VPN 保持工作的条件下验证 ChatGPT、剩余流量和防回环。不得以编译成功替代这项证据。

桌面工具曾两次打开 Debug App 超时。该观察尚不能判定应用自身启动失败，需要区分工具连接问题与应用窗口/生命周期问题。

## 公司 VPN 共存测试清单

执行前提：用户确认方便测试，并由用户连接 OpenVPN、EasyConnect、aTrust。Conductor 当前处于停止状态。只检查这些客户端已经建立的连接，不代用户登录或控制它们。

1. 记录当前路由与 DNS：`netstat -rn -f inet`、`netstat -rn -f inet6`、`scutil --dns`，并对每条公司网络内的已知地址执行 `route -n get <地址>`。只发现进程而没有路由证据时，标记为未确认。
2. 检查本地代理端口的监听进程及当前配置排除规则，确认实际联网进程（当前观察为 `ApexCore`）和必要辅助进程已经覆盖；VPN 升级后重新检查，不固定 utun 编号。
3. 用固定版本执行 `sing-box check`，备份当前配置并验证备份可读。仅在用户确认后应用经过检查的排除规则并启动 Conductor。
4. 启动后分别检查 ChatGPT、普通代理出口和每条公司内网目标的实际访问与出口日志；记录各目标的成功或失败、目标地址、路由接口和时间。不得将端口可连接或单次 DNS 成功当成完整业务验收。
5. 对比启动前后 IPv4、IPv6 路由和 DNS；验证 Google/国内站点走向符合用户当前选择，明确 `direct` 仍受系统路由影响。
6. 停止 Conductor，检查公司 VPN 仍由其客户端保持连接，确认路由、DNS 与启动前一致；必要时从备份恢复配置，并再次检查。出现异常时停止测试、保留证据，不自行重启或断开公司客户端。

当前只观察到三个客户端的后台服务，未观察到已登记公司网段的路由；不能据此认定它们已经连接。完整共存测试尚未执行。

## 实际界面观察补充

当前只读检查发现 `127.0.0.1:7890` 由 `/Applications/Fastlink-极速版.app/Contents/MacOS/ApexCore` 监听，而当前配置中的防回环规则仅列出旧版 `FastLinkCore` 和 `FastLink_Lite`。两者不匹配，不能认为新版 Fastlink 的防回环已经生效。需重新选择当前应用并保存后检查实际进程规则；本次没有修改用户配置或启动代理。

新增端口监听进程检查：在本机以 `CONDUCTOR_CHECK_LISTENER=127.0.0.1:7890` 运行隔离回归，实际返回 `ApexCore`。该检查只提供进程名称的辅助证据，不证明全部网络辅助进程均已排除；表单的真实点击路径仍待复验。

最新调试构建的表单已实测：编辑 `vpn-proxy-01`，点击“检查端口进程”后显示 `ApexCore` 未排除和重新选择 VPN 的提示；取消后返回配置页，没有保存或启动代理。

混合端口新交互已在最新调试构建实测：检测前保存禁用；检测 `127.0.0.1:7890` 后展示 HTTP、SOCKS5 成功和 UDP 握手已接受，选择 SOCKS5，保存变为可用；更改端口后检测结果清除且保存再次禁用。最后取消，没有写入正式配置。

当前 Fastlink 的混合端口实际握手回归通过：HTTP CONNECT 和 SOCKS5 CONNECT 成功，UDP ASSOCIATE 被接受；先检测未监听端口失败后重试，成功结果清除对应旧错误。UDP 数据往返仍未验证。临时配置扫描新版应用生成的 `ApexCore` direct 规则位于默认出口前，且通过 1.14.0 check；这不等于真实 TUN 防回环验证。

进一步通过 `127.0.0.1:7890` 的 SOCKS5 UDP relay 向 `1.1.1.1:53` 发出公开 `google.com` A 查询，收到匹配事务 ID 的 DNS 响应（DNS 数据 124 字节）。该证据证明本次 DNS UDP 往返，不证明所有 UDP 目的地和 QUIC 均可用，也未经过 Conductor TUN。

使用固定版 sing-box 和 `scripts/fixtures/local-socks-forward.json` 启动独立本地 HTTP 入站 `127.0.0.1:19374`，通过 SOCKS5 转发到 Fastlink `127.0.0.1:7890`；curl 请求 Apple 官网获得 HTTP 200，测试实例随后正常退出。未使用 TUN 或修改系统路由，因此尚不能证明 TUN 模式与公司 VPN 共存。

隔离实例增加 SOCKS 入站 `127.0.0.1:19375` 后，通过 sing-box → Fastlink SOCKS5 代理链向 `1.1.1.1:53` 发送 DNS 查询并收到匹配响应（DNS 数据 124 字节）；实例已退出。这验证了单次 UDP 数据往返，未验证 TUN 或所有 UDP 目的地。

对用户当前正式配置执行只读 `sing-box 1.14.0 check` 成功；再次读取 direct 进程名仍只有 `FastLinkCore`、`FastLink_Lite`，尚未覆盖当前监听进程 `ApexCore`。配置格式有效不代表实际防回环或转发成功。

随后通过已有应用连接读取到最新窗口：配置页存在“刷新”，编辑 HTTP 出口后输入 `localhost:0`，实际显示端口格式说明且保存禁用；取消返回配置页。最新界面连接已恢复，不能继续把桌面连接超时视为当前全局阻塞。固定版本校验与网络验证仍待完成。

最新设置页可见“选择 sing-box 1.14.0…”；点击“检查 sing-box”后仍保留 1.14.3 版本警告，没有被配置检查结果覆盖。日志页可正常导航，筛选、搜索与复制入口可见。尚未据此声明搜索、复制或运行中操作的完整交互通过。

实际截图确认配置页主要按钮和底部启动入口没有被版本错误提示遮挡。日志搜索输入无匹配内容后，旧提示误显示“启动代理后显示日志”，已改为区分无日志与无匹配；新增表单默认名称会避开现有出口，手动输入已有名称时提示更新。回环地址显示完整端点，远端 IPv4 仍脱敏。这些后续修改已经逻辑检查或编译验证，需重载最新进程后复验视觉行为。

通过 `com.hyfly.Conductor` 成功连接旧调试进程，验证 HTTP 编辑弹窗的地址、剩余流量及 FastLinkCore/FastLink_Lite 回填；输入 `localhost:0` 后保存禁用，取消可返回。删除确认显示影响与备份说明，取消后出口仍在。设置页导航正常，显示 1.14.3 开发运行时警告。这些结果只覆盖旧进程已加载的版本。

确认状态为“代理未运行”后退出旧进程，以加载最新构建；随后按应用路径启动和按标识连接仍超时，最新构建的窗口验证尚未完成。验证过程中未保存、删除正式配置或启动代理。

后续只读诊断确认最新调试进程 PID 12604 存活；1 秒主线程采样主要处于 AppKit 事件循环等待，没有观察到配置读取或子进程同步等待。按应用标识连接仍超时。证据支持继续排查窗口呈现/桌面工具连接，而不是据超时直接认定主线程死锁。采样文件位于 `/tmp/conductor-startup-sample.txt`，属于临时诊断产物。
2026-11-03：`scripts/check-auth-forward.py` 使用固定版 sing-box 1.14.0，在回环地址启动带用户名密码的 mixed 入站、本地 HTTP 目标和独立前置实例。通过 HTTP CONNECT 入站分别经 HTTP 和 SOCKS5 认证出口转发，正确凭据均收到预期响应；错误凭据均失败，目标服务请求计数没有增加。进程随后退出。未使用 TUN、外部代理或系统路由。初次使用普通 HTTP 代理请求时测试超时，改为显式 CONNECT 后成功；普通 HTTP 请求路径未验证通过，也不由此推断 TUN 结果。测试还观察到 sing-box mixed 入站在 SOCKS5 认证失败日志中输出所尝试的密码，因此此脚本仅使用固定测试凭据，实际服务日志需要限制访问。
2026-11-04：从上游下载 arm64 sing-box 1.14.0 归档，SHA-256 为 `a150c94012ff768b7261939cd236b9c8554127f45137230295d23a5660225cc9`，与先前记录一致。Release 构建与本地打包成功；ZIP 包含对应二进制和上游许可证。当前环境对生成的 App 执行 `codesign --verify --deep --strict` 返回 `CSSMERR_TP_NOT_TRUSTED`，该包未完成可信签名、公证、Intel 构建或 Homebrew 安装验证，不可视为正式发布物。
2026-11-04：公司 VPN 页面仍使用代码中的固定网段作为检测目标，尚未提供网段增删改或写入 TUN `route_exclude_address` 的功能；页面现明确标注这些目标不代表已写入排除配置。不能将此页面的检测结果视为公司流量绕过 TUN 的证明。网段管理、现有排除规则的保留以及真实系统路由共存仍待实施和验收。
2026-11-04 后续：公司 VPN 页面增加共享 TUN 排除网段编辑，读取并完整展示 `route_exclude_address`，保存时校验 CIDR、检查配置变化、执行固定版 sing-box check 并备份。临时配置验证新增、删除、无效输入和过期快照保护通过。当前尚不支持按客户端关联网段；规则集及其他排除字段不由此编辑器管理。未进行真实 TUN 和公司 VPN 共存验收。
2026-11-04 后续界面检查：最新 Debug 构建的公司 VPN 页面成功显示正式配置中的 TUN 排除列表及三个预设目标的覆盖数；点击“编辑排除网段”可打开编辑器，点击“取消”返回页面。此次未保存配置、未启动代理；该界面检查不证明真实 TUN 与公司 VPN 共存。
2026-11-04：普通 HTTP/SOCKS5 出口编辑表单目前只有剩余流量和简单域名两种范围，应用及 IP/CIDR 绑定尚不能在表单内新建或编辑；已有高级规则在编辑时保留。界面已说明限制，这不代表 PRD 中的多种绑定范围已完成。
2026-11-04 后续：普通代理出口新增 IP/CIDR 范围。单 IP 归一为 `/32` 或 `/128`；保存简单 IP 规则时保留已有简单域名和组合条件规则，并放在已有规则之后、自动 UDP 回退之前。临时配置通过固定版 sing-box 1.14.0 check；该证据不证明真实流量已命中，现有更高优先级规则仍可能先匹配。普通出口的应用绑定仍待实现。
2026-11-04 后续：普通代理出口增加“指定应用”，选择 `.app` 后使用包内识别到的可执行文件路径生成简单进程规则；冲突于所选 VPN 防回环路径时阻止保存。临时配置通过固定版 sing-box 1.14.0 check，覆盖旧域名、IP、组合规则保留和直连优先级；实际应用流量、辅助进程发现和真实 TUN 匹配尚未验收。
2026-11-04：最新 Debug 界面打开现有 HTTP 出口，确认地址和协议回填；切换到 IP/CIDR 时展示输入框且空值禁用保存，切换到指定应用时展示应用选择入口。随后取消，没有写入配置，也没有启动代理。界面显示现有 VPN 防回环进程路径部分不存在；真实流量仍需在用户授权的 TUN 环境中验收。
2026-11-04：使用 `scripts/check-vless-forward.py` 从当前正式配置提取 VLESS 出站，在临时目录和回环 HTTP 入站中分别请求 ChatGPT 与 Apple 的公开 HTTPS 地址。两者均未成功；脱敏 sing-box 日志显示连接 VLESS 服务器 TCP 端口时超时。该结果表明本次测试环境没有建立到服务器端口的连接，不能单独判断是服务器、防火墙还是本机网络路径导致；未使用 TUN、未修改正式配置或系统路由。
2026-11-04 后续：只读系统路由查询显示当前 VLESS 服务器目标经 `en0`；本地 `127.0.0.1:7890` 有 `ApexCore` 监听，通过该 HTTP 代理请求 Apple 公共 HTTPS 页面获得 HTTP 200。这说明本机代理在该次公共请求可用，不证明 VPS 服务可用，也不能将 VLESS 直连超时归因于服务器或客户端某一方。

2026-11-17：交互层按 INTERACTION 第 3、9 节补齐，并修复一处证据确凿的阻断缺陷。`runAppleScript` 原先在主 actor 上同步等待 `osascript` 与管理员授权，启动/停止期间整个窗口无法绘制；现改为后台队列 + continuation，`正在启动…`/`正在停止…` 与禁用态可见（`ConductorController.swift` 的 `runAppleScript`/`launchProcess`/`stopPrivilegedProcess`）。同时删除从未赋值的 `process`/`outputPipe`，`isRunning` 只依据 `privilegedPID`+PID 文件，`refreshStatus` 把失效的 `.stopping` 归位。

已执行的验证：Debug 构建通过；`swiftc` 回归脚本通过并新增 6 条日志筛选断言（`scripts/OperationChecks.swift`）；真实窗口操作确认——状态栏错误摘要切换到日志页并预选 Warning/Error 且显示 2 行 `ERROR`、菜单栏「查看日志」「代理出口」跳转正确（12 个菜单项与启用态逐项核对）、「自动滚动到底部」关闭后出现「回到最新」且可恢复、版本门拦截启动并写入 `ERROR sing-box 配置检查失败：`、未运行态「退出」立即结束进程。

尚缺证据：代理运行中的「退出」确认框，以及真实管理员授权下的界面响应速度。本机仅安装 sing-box 1.14.4，启动被固定版本门拒绝，因此上述两项无法在本次环境触发；`isRunning` 分支与 `stop()` 使用同一判据，但未实际点击过运行态退出。

顺带修正一处交互缺陷：失败文本原本不含 `error`/`fatal`/`warning`，错误摘要入口跳到 Warning/Error 筛选后必然显示「没有匹配的日志」。现在所有失败日志统一带 `ERROR` 前缀，运行时版本不匹配也记入日志。

2026-11-17：运行时版本门由“精确匹配 1.14.0”改为“最低版本 1.14.0”。新增单一判据 `ConductorController.isSupportedSingBoxVersion`（`ConductorController.swift:204`），DEBUG 选择器、`checkRuntime`、`requireSupportedRuntime` 三处共用；只接受纯数字与点号构成的版本（`1.14.0-beta.1`、`1.14.0+build`、`garbage` 均拒绝），高于基线一律放行。打包脚本用 `sort -V` 实现同一规则，并对无法解析的版本单独拒绝；内置副本比对改为与该次校验通过的版本一致，不再硬编码。

已执行的验证：Debug 构建通过；回归脚本新增 19 条版本判据断言（8 个接受、11 个拒绝，含预发布与构建元数据）以及一条“低于基线禁止启动”的真实用例（用 `1.13.9` 替身运行 `checkRuntime` 与 `start`，断言 `.warning`、`.configurationError` 与不进入运行态）；`CONDUCTOR_CHECK_RUNTIME=/opt/homebrew/bin/sing-box`（真实 1.14.4）通过全部真实检查——TUN 排除、IP/CIDR 与应用绑定、VLESS 导入、HTTP 默认出口与 UDP/443 reject、历史恢复；`scripts/package-release.sh` 用 1.14.4 完成构建与打包并输出 SHA-256；门控矩阵逐一核对 `1.13.9`/`1.14.0`/`1.14.4`/`1.15.0`/`2.0.0` 放行、预发布与非法串拒绝。

尚缺证据：真实 App 内点击验证未能在本次完成，辅助访问授权在会话中失效（`AXIsProcessTrusted()` 返回 false），因此“设置页显示 1.14.4 且状态为版本满足最低要求”只有构建与单元级证据。高于基线的版本允许运行，但不同版本的路由与 DNS 行为差异未做回归；发布物仍打包 1.14.0，非 1.14.0 版本运行不代表发布基线已验收。

2026-11-17：补齐应用图标。此前 `AppIcon.appiconset/Contents.json` 声明了 10 个尺寸槽位但没有任何 `filename`，`AccentColor` 也只有空 `idiom` 而无颜色值，因此 `actool` 虽然执行却产出空的 `Contents/Resources/`，应用在 Dock 与 Finder 中显示通用文档图标，配置卡片上 `.tint` 也因此无主题色。

现在由单一 1024 px 母版生成 16/32/128/256/512 的 1x 与 2x 共 10 张 PNG（CoreGraphics 绘制，未引入依赖），`Contents.json` 逐项绑定 `filename`；`AccentColor` 补充 sRGB 值 0.259/0.216/0.627，与图标底色一致。

已执行的验证：Debug 与 Release 构建后 `Contents/Resources/` 出现 `AppIcon.icns` 与 `Assets.car`；`Info.plist` 的 `CFBundleIconFile` 与 `CFBundleIconName` 均为 `AppIcon`；从 bundle 读取 `Assets.car` 得到 10 个位图（16×16 至 1024×1024）与实际 AccentColor 值；`NSWorkspace.icon(forFile:)` 在 LaunchServices 重新注册后返回新图标；Release ZIP 内含 `AppIcon.icns` 与 `Assets.car`；回归脚本与 `git diff --check` 通过。

尚缺证据：最终 Dock/菜单栏的屏幕截图未能采集——本会话的屏幕录制授权也已失效（`screencapture -l` 返回 “could not create image from window”），因此“肉眼所见与 icns 一致”只有程序化读取证据。重新登录或重新授权后应补一次视觉确认。

2026-11-17：补齐发布脚本。原脚本只做版本/架构/许可证检查，然后把运行时塞进已被 Xcode 签名的应用就不再重签，也没有 `SHA256SUMS`，更没有校验产物本身的完整性。实测确认两个缺陷：打包后 `codesign --verify --strict` 返回 `a sealed resource is missing or invalid`（退出码 1），而文档的发布结构要求 `SHA256SUMS`。

现在的脚本行为：版本号从构建产物的 `CFBundleShortVersionString` 读取并用于 ZIP 命名，要求与 `Casks/conductor.rb.template` 的 `version` 完全一致，否则拒绝；打包前校验 `AppIcon.appiconset` 每个槽位都绑定了 `filename` 且文件存在；构建后确认 `AppIcon.icns` 与 `Assets.car` 存在且不早于本次构建；无 `CODE_SIGN_IDENTITY` 时改为 ad-hoc 重签，使签名封印有效；`NOTARY_PROFILE` 与 `CODE_SIGN_IDENTITY` 同时提供时执行 notarytool 提交、staple 与 validate，只给其中一个则拒绝；每个架构的摘要写入 `build/release/SHA256SUMS`，重复运行替换同名行并保留另一架构的行。

顺带修正版本漂移：`MARKETING_VERSION` 由 `1.0` 改为 `1.0.0`，与应用包、ZIP 与 Cask 对齐；设置页不再硬编码 `"1.0"`，改读 `ConductorController.appVersion`。

已执行的验证：正常路径完整打包成功，`AppIcon.icns`/`Assets.car`/`bin` 均在包内；`shasum -a 256 -c SHA256SUMS` 通过；解压后的 App `codesign --verify --deep --strict` 通过（此前失败）；重复运行后 `SHA256SUMS` 的 arm64 行被更新而保留的 x86_64 测试行未被删除；拒绝路径逐项验证为退出码 1 并给出可读原因——Cask 版本改为 1.0.1 时拒绝、10 个图标槽位解绑 `filename` 时拒绝、`NOTARY_PROFILE` 缺 `CODE_SIGN_IDENTITY` 时拒绝、二进制缺失/许可证缺失拒绝；Debug 构建与回归脚本通过。

尚缺证据：Intel 架构产物、真实 Developer ID 签名、notarytool 公证与 staple、以及在干净机器上的 Cask 安装。这些都需要对应凭据或硬件，未在本次执行。
