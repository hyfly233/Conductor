import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: ConductorController
    @State private var editor: ConfigurationEditor?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Label("Conductor", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.weight(.semibold))
                Picker("页面", selection: $controller.selectedSection) {
                    ForEach(ControlSection.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 520)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            Group {
                switch controller.selectedSection {
                case .configuration: ConfigurationPage(controller: controller, editor: $editor)
                case .companyVPN: CompanyVPNPage(controller: controller)
                case .settings: SettingsPage(controller: controller)
                case .logs: LogsPage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RuntimeStatusBar(controller: controller) { controller.selectedSection = .logs; controller.logFilter = .errors }
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(item: $editor) { ConfigurationEditorSheet(controller: controller, editor: $0) }
        .task {
            controller.refreshStatus()
            controller.reloadConfigurationSummary()
            controller.reloadHistory()
            await controller.checkRuntime()
        }
    }
}

private enum ConfigurationEditor: String, Identifiable {
    case vless, socks, http, mixed
    var id: String { rawValue }
}

private struct PageHeader<Action: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }
}

private struct ConfigurationPage: View {
    @ObservedObject var controller: ConductorController
    @Binding var editor: ConfigurationEditor?
    @State private var pendingDeletion: ProxyConfiguration?
    @State private var editingProxy: ProxyConfiguration?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "配置", subtitle: "管理代理出口以及哪些流量使用它们") {
                    HStack {
                    Button {
                        controller.reloadConfigurationSummary()
                        controller.reloadHistory()
                    } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(controller.isBusy)
                    Menu {
                        Button("导入 VLESS URL…") { editor = .vless }
                        Button("添加 SOCKS5 出口…") { editor = .socks }
                        Button("添加 HTTP 出口…") { editor = .http }
                        Button("添加混合端口…") { editor = .mixed }
                    } label: { Label("添加代理出口", systemImage: "plus") }
                    .disabled(controller.isRunning || controller.isBusy)
                    }
                }
                if controller.isRunning {
                    Label("以下显示磁盘配置；外部修改需停止并重新启动代理后生效。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.configurationReadError {
                    ContentUnavailableView {
                        Label("无法加载配置", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                        Text(controller.configPath).font(.caption.monospaced()).textSelection(.enabled)
                    } actions: {
                        Button("打开配置目录") { controller.openConfigDirectory() }
                        Button("重试") { controller.reloadConfigurationSummary() }
                    }
                } else if controller.proxyConfigurations.isEmpty {
                    ContentUnavailableView {
                        Label("尚未添加代理配置", systemImage: "network.slash")
                    } description: {
                        Text("导入 VLESS 节点，或添加提供本地代理端口的 VPN 工具。")
                    } actions: {
                        Button("导入 VLESS") { editor = .vless }
                            .disabled(controller.isRunning || controller.isBusy)
                    }
                } else {
                    let vless = controller.proxyConfigurations.filter { $0.type == "VLESS" }
                    let local = controller.proxyConfigurations.filter { $0.type != "VLESS" }
                    if !vless.isEmpty { configurationGroup("代理节点", items: vless) }
                    if !local.isEmpty { configurationGroup("本地代理出口", items: local) }
                }
            }.padding(24)
        }
        .sheet(item: $editingProxy) { item in
            ConfigurationEditorSheet(controller: controller, editor: item.type == "HTTP" ? .http : .socks, existingTag: item.id)
        }
        .alert("删除代理出口？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let item = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await controller.deleteProxyConfiguration(id: item.id) }
            }
        } message: {
            if let item = pendingDeletion {
                Text("将删除“\(item.name)”及其流量绑定。若它是剩余流量出口，剩余流量将恢复直连。\(controller.dnsUsesOutbound(tag: item.id) ? "使用此出口的 DNS 将移除代理设置，可能改为直连。" : "")此操作会先备份当前配置。")
            }
        }
    }

    private func configurationGroup(_ title: String, items: [ProxyConfiguration]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(items) { item in
                ProxyConfigurationCard(
                    item: item,
                    test: { Task { await controller.testProxyConfiguration(id: item.id) } },
                    edit: {
                        if item.id == "chatgpt-vless" { editor = .vless }
                        else if item.type == "VLESS" { controller.openControlPanel() }
                        else { editingProxy = item }
                    },
                    delete: { pendingDeletion = item },
                    mutationDisabled: controller.isRunning || controller.isBusy
                )
            }
        }
    }
}

private struct ProxyConfigurationCard: View {
    let item: ProxyConfiguration
    let test: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let mutationDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.type).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.tint.opacity(0.14), in: Capsule())
                Text(item.name).font(.headline)
                if let source = item.sourceSummary {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(testStatus, systemImage: item.health.symbol).font(.caption).foregroundStyle(healthColor)
                    .help("此测试仅检查 TCP 端口，不验证代理协议或目标网站是否可用。")
            }
            Text(item.endpoint).font(.system(.body, design: .monospaced))
            HStack {
                Label(item.bindingSummary, systemImage: "arrow.triangle.branch").foregroundStyle(.secondary)
                Spacer()
                Button("测试端口", action: test).disabled(item.health == .checking)
                    .help("检查出口服务器的 TCP 端口连通性")
                Button(item.id == "chatgpt-vless" ? "更新 URL" : "编辑", action: edit).disabled(mutationDisabled)
                Button("删除", role: .destructive, action: delete)
                    .disabled(mutationDisabled)
                    .help(mutationDisabled ? "请先停止代理" : "删除该出口及其流量绑定")
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
    }

    private var healthColor: Color {
        switch item.health {
        case .healthy: .green
        case .warning: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private var testStatus: String {
        switch item.health {
        case .healthy: "端口可连接"
        case .failed: "端口连接失败"
        default: item.health.rawValue
        }
    }
}

private struct ConfigurationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: ConductorController
    let editor: ConfigurationEditor
    let existingTag: String?
    private let editingConfig: Data?
    private let wasDefault: Bool
    @State private var name = "vpn-proxy-01"
    @State private var endpoint: String
    @State private var domains = ""
    @State private var destinationIPs = ""
    @State private var destinationAppPaths: [String] = []
    @State private var destinationAppName: String?
    @State private var vlessURI = ""
    @State private var scope: ProxyRouteScope
    @State private var proxyKind: String
    @State private var username: String
    @State private var password: String
    @State private var selectedApplication: URL?
    @State private var excludedProcessPaths: [String] = []
    @State private var probeResult: MixedProxyProbeResult?
    @State private var isProbing = false
    @State private var listenerNames: [String]?
    @State private var checkingListener = false

    init(controller: ConductorController, editor: ConfigurationEditor, existingTag: String? = nil) {
        self.controller = controller
        self.editor = editor
        self.existingTag = existingTag
        self.editingConfig = existingTag == nil ? nil : try? Data(contentsOf: URL(fileURLWithPath: controller.configPath))
        let values = existingTag.flatMap { controller.proxyEditorValues(tag: $0) }
        self.wasDefault = values?.isDefault ?? false
        _name = State(initialValue: existingTag ?? controller.nextProxyTag)
        _endpoint = State(initialValue: values?.endpoint ?? (editor == .vless ? "" : "127.0.0.1:7890"))
        _scope = State(initialValue: values.map { $0.isDefault ? .remaining : (!$0.domains.isEmpty ? .domains : (!$0.cidrs.isEmpty ? .cidrs : (!$0.applications.isEmpty ? .applications : .domains))) } ?? (editor == .vless ? .domains : .remaining))
        _domains = State(initialValue: values?.domains ?? "")
        _destinationIPs = State(initialValue: values?.cidrs ?? "")
        _destinationAppPaths = State(initialValue: values?.applications ?? [])
        _username = State(initialValue: values?.username ?? "")
        _password = State(initialValue: values?.password ?? "")
        _excludedProcessPaths = State(initialValue: values?.paths ?? [])
        let autoDetect = existingTag.map { controller.usesMixedProxyDetection(tag: $0) } ?? (editor == .mixed)
        _proxyKind = State(initialValue: autoDetect ? "mixed" : (editor == .http ? "http" : "socks"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingTag != nil ? "编辑代理出口" : (editor == .vless ? "导入 VLESS Reality" : "添加代理出口")).font(.title2.bold())
            if editor == .vless {
                TextField("粘贴 vless:// 地址", text: $vlessURI)
                    .disabled(controller.isBusy)
                HStack {
                    Button("从剪贴板粘贴") {
                        vlessURI = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    .disabled(controller.isBusy)
                    Spacer()
                }
                LabeledContent("目标应用", value: "ChatGPT")
                Text("敏感参数不会显示在日志中。导入会更新 ChatGPT 应用和域名绑定。")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.proxyConfigurations.contains(where: { $0.id == "chatgpt-vless" }) {
                    Label("保存将替换现有 ChatGPT 节点，并备份当前配置。", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if existingTag != nil && editingConfig == nil {
                    Label("无法读取原配置，请关闭窗口后重试。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                TextField("出口名称", text: $name)
                    .disabled(existingTag != nil || isProbing || controller.isBusy)
                if existingTag == nil, controller.existingOutboundType(tag: name) != nil {
                    Label("此名称已存在，请更换名称；如需修改已有出口，请使用配置卡片上的“编辑”。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("代理协议", selection: $proxyKind) {
                    Text("SOCKS5").tag("socks")
                    Text("HTTP").tag("http")
                    Text("混合端口").tag("mixed")
                }.pickerStyle(.segmented)
                    .disabled(isProbing || controller.isBusy)
                TextField("IP/主机:端口", text: $endpoint)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: endpoint) { _, _ in probeResult = nil }
                    .onChange(of: endpoint) { _, _ in listenerNames = nil }
                    .disabled(checkingListener || isProbing || controller.isBusy)
                TextField("用户名（可选）", text: $username)
                    .onChange(of: username) { _, _ in probeResult = nil }
                    .disabled(isProbing || controller.isBusy)
                SecureField("密码（可选）", text: $password)
                    .onChange(of: password) { _, _ in probeResult = nil }
                    .disabled(isProbing || controller.isBusy)
                if !credentialsValid {
                    Text("用户名和密码需同时填写，各不超过 255 字节；用户名不能包含冒号。")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("认证信息保存在本机配置中；HTTP Basic 和 SOCKS5 认证本身不加密。")
                    .font(.caption).foregroundStyle(.secondary)
                if !endpoint.isEmpty && !ConductorController.isValidProxyEndpoint(endpoint) {
                    Text("请输入主机和 1–65535 范围内的端口，例如 127.0.0.1:7890 或 [::1]:7890。")
                        .font(.caption).foregroundStyle(.red)
                }
                if proxyKind == "mixed" {
                    Button(isProbing ? "正在检测…" : "检测协议") {
                        Task {
                            isProbing = true
                            probeResult = await controller.probeMixedProxy(endpoint: endpoint, username: username, password: password)
                            isProbing = false
                        }
                    }.disabled(isProbing || controller.isBusy || !credentialsValid || !ConductorController.isValidProxyEndpoint(endpoint))
                    mixedProbeStatus
                }
                Picker("流量范围", selection: $scope) {
                    ForEach(ProxyRouteScope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                    .disabled(isProbing || controller.isBusy)
                Text("此表单管理剩余流量和简单域名、IP、应用路径规则；其他范围及组合条件规则会保留。")
                    .font(.caption).foregroundStyle(.secondary)
                if wasDefault && scope != .remaining {
                    Label("保存后，剩余流量将恢复直连；其他保留规则仍会先匹配。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if !wasDefault && scope == .remaining {
                    Label("保存后，此出口将接管剩余流量；现有显式规则仍会先匹配。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if existingTag != nil && scope != .remaining {
                    Text("清空当前范围并保存会移除该范围的简单规则，其他规则保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if scope == .domains {
                    TextField("域名后缀，逗号分隔", text: $domains)
                        .disabled(isProbing || controller.isBusy)
                    Text("例如 google.com, github.com；匹配这些域名及其子域名。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if scope == .cidrs {
                    TextField("IP/CIDR，逗号分隔", text: $destinationIPs)
                        .disabled(isProbing || controller.isBusy)
                    Text("例如 192.0.2.1, 198.51.100.0/24；已有更高优先级规则仍先匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if scope == .applications {
                    HStack {
                        Button("选择目标应用…") { chooseTargetApplication() }
                        Text(destinationAppName ?? (destinationAppPaths.isEmpty ? "尚未选择" : "已保存的应用进程"))
                            .foregroundStyle(.secondary)
                        if !destinationAppPaths.isEmpty {
                            Button("清空目标") { destinationAppPaths = []; destinationAppName = nil }
                        }
                    }.disabled(isProbing || controller.isBusy)
                    if destinationAppName != nil && destinationAppPaths.isEmpty {
                        Text("未发现可执行进程，请选择其他应用。")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if !destinationAppPaths.isEmpty {
                        Text("应用路径：\(destinationAppPaths.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if destinationAppPaths.contains(where: { !FileManager.default.isExecutableFile(atPath: $0) }) {
                            Text("部分应用进程不存在，请重新选择应用。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !Set(destinationAppPaths).isDisjoint(with: Set(excludedProcessPaths)) {
                            Text("目标应用与防回环排除进程重复，请选择不同的应用。")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    Text("应用的网络进程按路径匹配；已有更高优先级规则仍先匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("使用本机 VPN 代理时，其联网进程可能再次进入此出口并形成代理回环。请选择对应应用进行排除。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("选择本机 VPN 应用…") { chooseVPNApplication() }
                    if let selectedApplication {
                        Text(selectedApplication.lastPathComponent).foregroundStyle(.secondary)
                    } else if !excludedProcessPaths.isEmpty {
                        Text("已保存的进程排除").foregroundStyle(.secondary)
                    }
                    if selectedApplication != nil || !excludedProcessPaths.isEmpty {
                        Spacer()
                        Button("清除") {
                            self.selectedApplication = nil
                            excludedProcessPaths = []
                        }
                    }
                }
                .disabled(isProbing || controller.isBusy)
                if isLocalEndpoint {
                    Text("按端口检查本机监听进程；多个进程或地址同时监听时，结果可能包含其他监听者。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(checkingListener ? "正在检查端口进程…" : "检查端口进程") {
                        Task {
                            checkingListener = true
                            listenerNames = await controller.localListenerNames(endpoint: endpoint) ?? []
                            checkingListener = false
                        }
                    }.disabled(checkingListener || isProbing || controller.isBusy)
                    if let listenerNames {
                        if listenerNames.isEmpty {
                            Text("无法确定监听进程，请确认代理已启动并检查权限。")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            let exclusions = Set(excludedProcessPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
                            let missing = listenerNames.filter { !exclusions.contains($0) }
                            Text(missing.isEmpty ? "监听进程名称已列入排除：\(listenerNames.joined(separator: "、"))；其他辅助进程仍需检查。" : "监听进程未全部排除：\(missing.joined(separator: "、"))；请重新选择对应 VPN 应用。")
                                .font(.caption).foregroundStyle(missing.isEmpty ? .green : .orange)
                        }
                    }
                }
                if proxyKind == "http" && scope == .remaining {
                    Label("HTTP 出口仅支持 TCP；将拒绝 UDP/443，使浏览器回退 TCP。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !excludedProcessPaths.isEmpty {
                    Label("将排除 \(excludedProcessPaths.count) 个联网进程，包括 \(excludedProcessPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))。", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.green)
                    if excludedProcessPaths.contains(where: { !FileManager.default.isExecutableFile(atPath: $0) }) {
                        Label("部分排除进程不存在或不可执行；VPN 更新后请重新选择当前应用，以免发生代理回环。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if isLocalEndpoint && scope == .remaining {
                    Text("尚未选择 VPN 应用。保存后可能出现代理回环。")
                        .font(.caption.bold()).foregroundStyle(.red)
                }
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if isProbing { ProgressView("正在验证代理协议，请稍候…").controlSize(.small) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(checkingListener || isProbing || controller.isBusy)
                Button(saveButtonTitle) {
                    Task {
                        if editor == .vless { await controller.importVLESSURI(vlessURI, targetApp: "chatgpt") }
                        else {
                            var actualKind = proxyKind
                            var supportsUDP = proxyKind == "socks"
                            if proxyKind == "mixed" {
                                guard let result = probeResult else { return }
                                guard let selectedKind = result.selectedKind else { return }
                                actualKind = selectedKind
                                supportsUDP = result.supportsUDP
                            }
                            await controller.saveProxy(
                                tag: name,
                                kind: actualKind,
                                endpoint: endpoint,
                                domains: domains,
                                useAsDefault: scope == .remaining,
                                excludedProcessPaths: excludedProcessPaths,
                                supportsUDP: supportsUDP,
                                wasAutoDetected: proxyKind == "mixed",
                                credentials: (username, password),
                                requireNew: existingTag == nil,
                                expectedConfig: editingConfig,
                                destinationCIDRs: scope == .cidrs ? destinationIPValues : nil,
                                destinationAppPaths: scope == .applications ? destinationAppPaths : nil
                            )
                        }
                        if controller.lastError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(!isValid || controller.isBusy || isProbing || checkingListener || (proxyKind == "mixed" && probeResult?.selectedKind == nil))
            }
        }.padding(24).frame(width: 560)
            .interactiveDismissDisabled(checkingListener || isProbing || controller.isBusy)
    }

    private var isValid: Bool {
        if editor == .vless { return vlessURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("vless://") }
        let endpointValid = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ConductorController.isValidProxyEndpoint(endpoint)
        let nameAvailable = existingTag != nil || controller.existingOutboundType(tag: name) == nil
        let scopeValid: Bool
        switch scope {
        case .remaining: scopeValid = true
        case .domains: scopeValid = existingTag != nil || !domains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .cidrs: scopeValid = (existingTag != nil || !destinationIPValues.isEmpty) && destinationIPValues.allSatisfy { ConductorController.normalizedIPOrCIDR($0) != nil }
        case .applications: scopeValid = (existingTag != nil || !destinationAppPaths.isEmpty) && Set(destinationAppPaths).isDisjoint(with: Set(excludedProcessPaths))
        }
        return endpointValid && nameAvailable && (existingTag == nil || editingConfig != nil) && credentialsValid && scopeValid
    }

    private var destinationIPValues: [String] {
        destinationIPs.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    private var credentialsValid: Bool {
        (username.isEmpty && password.isEmpty) ||
            (!username.isEmpty && !password.isEmpty && !username.contains(":") && username.utf8.count <= 255 && password.utf8.count <= 255)
    }

    private var isLocalEndpoint: Bool {
        endpoint.hasPrefix("127.") || endpoint.hasPrefix("localhost:") || endpoint.hasPrefix("[::1]:")
    }

    private var saveButtonTitle: String {
        if editor == .vless { return "导入" }
        if isProbing { return "正在探测…" }
        return "校验并保存"
    }

    @ViewBuilder private var mixedProbeStatus: some View {
        if let result = probeResult {
            VStack(alignment: .leading, spacing: 4) {
                probeLine("HTTP CONNECT", available: result.httpAvailable)
                probeLine("SOCKS5 CONNECT", available: result.socksTCPAvailable)
                Label(result.socksUDPAvailable ? "SOCKS5 UDP：握手已接受，数据转发未验证" : "SOCKS5 UDP：未通过握手检测", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let kind = result.selectedKind {
                    Text("实际出口：\(kind == "socks" ? "SOCKS5" : "HTTP")\(result.supportsUDP ? "" : "（仅 TCP）")")
                        .font(.caption.bold())
                    if !result.supportsUDP && scope == .remaining {
                        Text("将拒绝 UDP/443，使浏览器快速回退到 TCP。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("HTTP 与 SOCKS5 检测均失败。请确认代理已连接、端口和认证信息正确，然后重试；配置尚未保存。")
                        .font(.caption.bold()).foregroundStyle(.red)
                }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("请先检测 HTTP、SOCKS5 TCP 和 SOCKS5 UDP 握手，确认实际出口协议后保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func probeLine(_ title: String, available: Bool) -> some View {
        Label("\(title)：\(available ? "探测成功" : "探测失败")", systemImage: available ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption).foregroundStyle(available ? .green : .secondary)
    }

    private func chooseVPNApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择提供代理端口的 VPN 应用"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedApplication = url
        excludedProcessPaths = controller.executablePaths(inApplication: url)
    }

    private func chooseTargetApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择需要代理的应用"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationAppName = url.lastPathComponent
        destinationAppPaths = controller.executablePaths(inApplication: url)
    }
}

private struct CompanyVPNPage: View {
    @ObservedObject var controller: ConductorController
    @State private var evidence: CompanyVPNObservation?
    @State private var editingExclusions = false
    @State private var exclusionText = ""
    @State private var exclusionSnapshot: Data?
    @State private var exclusionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "公司 VPN", subtitle: "只检测客户端、接口和公司网段，不控制 VPN 连接") {
                    Button { Task { await controller.inspectCompanyVPNs() } } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                }
                GroupBox("TUN 排除网段") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let exclusions = controller.tunExclusions() {
                            Text(exclusions.values.isEmpty ? "尚未配置排除网段" : exclusions.values.joined(separator: "、"))
                                .textSelection(.enabled)
                            Button("编辑排除网段…") {
                                exclusionText = exclusions.values.joined(separator: "\n")
                                exclusionSnapshot = exclusions.snapshot
                                exclusionError = nil
                                editingExclusions = true
                            }.disabled(controller.isRunning || controller.isBusy)
                        } else {
                            Text("需要一个启用 auto_route 的 TUN 入站，才能编辑排除网段。")
                                .foregroundStyle(.secondary)
                        }
                        Text("排除后由系统路由决定去向；请先确认公司 VPN 的路由。修改在下次启动代理时生效。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                ForEach(controller.companyVPNs) { vpn in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(vpn.name).font(.headline); Spacer()
                            Text(vpn.state.rawValue).foregroundStyle(vpn.state == .connected ? .green : .secondary)
                        }
                        LabeledContent("候选接口", value: vpn.interfaceName ?? "未确认")
                        LabeledContent("预设检测目标", value: vpn.networks.joined(separator: "、"))
                        if let exclusions = controller.tunExclusions() {
                            let covered = vpn.networks.filter { network in exclusions.values.contains { ConductorController.cidr(network, isCoveredBy: $0) } }.count
                            LabeledContent("显式网段排除覆盖", value: "\(covered)/\(vpn.networks.count) 个检测目标")
                        }
                        Text("这些网段仅用于路由检测，不代表已写入 TUN 排除配置。路由命中隧道也不代表已确认接口归属。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let date = vpn.checkedAt { Text("检查于 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if let exclusions = controller.tunExclusions() {
                                let missing = vpn.networks.filter { network in !exclusions.values.contains { ConductorController.cidr(network, isCoveredBy: $0) } }
                                Button("添加预设网段…") {
                                    exclusionText = (exclusions.values + missing).joined(separator: "\n")
                                    exclusionSnapshot = exclusions.snapshot
                                    exclusionError = nil
                                    editingExclusions = true
                                }.disabled(missing.isEmpty || controller.isRunning || controller.isBusy)
                                .help(missing.isEmpty ? "预设检测目标已被显式排除网段覆盖" : "预填未覆盖网段，检查后再保存")
                            }
                            Button("查看路由证据") { evidence = vpn }
                        }
                    }.padding(16).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(24)
        }
        .sheet(item: $evidence) { vpn in
            VStack(alignment: .leading, spacing: 12) {
                Text("\(vpn.name) 路由证据").font(.title2.bold())
                ScrollView { Text(vpn.evidence).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                HStack { Spacer(); Button("关闭") { evidence = nil } }
            }.padding(24).frame(width: 620, height: 420)
        }
        .sheet(isPresented: $editingExclusions, onDismiss: { controller.clearError(ifMatching: exclusionError) }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑 TUN 排除网段").font(.title2.bold())
                Text("每行一个 IPv4 或 IPv6 CIDR。此处编辑 route_exclude_address；删除某行会移除对应排除。其他排除规则保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $exclusionText).font(.system(.body, design: .monospaced)).border(.separator)
                    .onChange(of: exclusionText) { _, _ in
                        controller.clearError(ifMatching: exclusionError)
                        exclusionError = nil
                    }
                    .disabled(controller.isBusy)
                if let error = exclusionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("取消") {
                        controller.clearError(ifMatching: exclusionError)
                        editingExclusions = false
                    }.disabled(controller.isBusy)
                    Button("检查并保存") {
                        guard let snapshot = exclusionSnapshot else { return }
                        let values = exclusionText.split(whereSeparator: { $0.isNewline || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Task {
                            await controller.saveTUNExclusions(values, expectedConfig: snapshot)
                            exclusionError = controller.lastError
                            if exclusionError == nil { editingExclusions = false }
                        }
                    }.buttonStyle(.borderedProminent).disabled(controller.isBusy || controller.isRunning)
                }
            }.padding(24).frame(width: 560, height: 400)
                .interactiveDismissDisabled(controller.isBusy)
        }
    }
}

private struct SettingsPage: View {
    @ObservedObject var controller: ConductorController
    @State private var restoring: ConfigurationHistoryItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "设置", subtitle: "运行时、配置文件和历史版本") { EmptyView() }
                GroupBox("运行时") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Conductor", value: "1.0")
                        LabeledContent("sing-box", value: "\(controller.runtimeVersion)（\(controller.singBoxPath.contains(".app/Contents/Resources") ? "内置" : "开发环境")）")
                        LabeledContent("状态") { Label(controller.runtimeHealth.rawValue, systemImage: controller.runtimeHealth.symbol) }
                        Text(controller.singBoxPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
#if DEBUG
                        Button("选择 sing-box 1.14.0…") { Task { await controller.selectDevelopmentRuntime() } }
                            .disabled(controller.isRunning || controller.isBusy)
#endif
                        HStack {
                            Spacer()
                            Button(controller.runtimeHealth == .checking ? "正在检查…" : "检查 sing-box") {
                                Task {
                                    await controller.checkRuntime()
                                    if controller.runtimeHealth == .healthy { await controller.validateConfiguration() }
                                }
                            }
                            .disabled(controller.isBusy || controller.runtimeHealth == .checking)
                        }
                    }.padding(8)
                }
                GroupBox("配置文件") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(controller.configPath).font(.caption.monospaced()).textSelection(.enabled)
                        HStack { Spacer(); Button("打开文件") { controller.openControlPanel() }; Button("打开目录") { controller.openConfigDirectory() } }
                    }.padding(8)
                }
                GroupBox("历史配置") {
                    if controller.configurationHistory.isEmpty { Text("暂无历史配置").foregroundStyle(.secondary).padding(8) }
                    else {
                        VStack(spacing: 0) {
                            ForEach(controller.configurationHistory) { item in
                                HStack {
                                    Text(item.createdAt.formatted(date: .numeric, time: .standard))
                                    Text(item.reason).foregroundStyle(.secondary); Spacer()
                                    Button("查看") { NSWorkspace.shared.open(item.url) }
                                    Button("恢复") { restoring = item }.disabled(controller.isRunning || controller.isBusy)
                                }.padding(.vertical, 8)
                                Divider()
                            }
                        }.padding(.horizontal, 8)
                    }
                }
            }.padding(24)
        }
        .alert("恢复这份历史配置？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("取消", role: .cancel) { restoring = nil }
            Button("恢复配置") {
                guard let item = restoring else { return }
                restoring = nil
                Task { await controller.restoreHistory(item) }
            }
        } message: {
            if let item = restoring {
                Text("将恢复 \(item.createdAt.formatted(date: .numeric, time: .standard)) 的配置（\(item.reason)）。恢复前会检查所选版本并备份当前配置。")
            }
        }
    }
}

private struct LogsPage: View {
    @ObservedObject var controller: ConductorController
    @State private var search = ""
    @State private var followsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日志").font(.title.bold())
                Picker("筛选", selection: $controller.logFilter) { ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                TextField("搜索日志", text: $search).textFieldStyle(.roundedBorder)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visibleLines.joined(separator: "\n"), forType: .string)
                }.disabled(visibleLines.isEmpty)
                Menu {
                    Button("清空当前显示") { controller.clearDisplayedLogs() }
                    Button("打开日志目录") { controller.openLogFile() }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(24)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if visibleLines.isEmpty {
                            Text(controller.logs.isEmpty ? "暂无日志。启动代理或执行检查后将在这里显示记录。" : "没有匹配的日志，请调整筛选或搜索条件。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                                logLine(line).id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .onChange(of: visibleLines.count) { _, _ in
                    guard followsLatest, let last = visibleLines.indices.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Toggle("自动滚动到底部", isOn: $followsLatest)
                if !followsLatest {
                    Button("回到最新") { followsLatest = true }
                }
                Spacer()
                Text("共 \(visibleLines.count) 行").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }
    }

    private func logLine(_ line: String) -> some View {
        Text(highlighted(line))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }

    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line.isEmpty ? " " : line)
        for token in Self.highlightTokens {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text[searchRange].range(of: token, options: .caseInsensitive) {
                text[found].foregroundColor = Self.tokenColor(for: token)
                text[found].font = .system(.caption, design: .monospaced).bold()
                guard found.upperBound < searchRange.upperBound else { break }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return text
    }

    private var visibleLines: [String] {
        ConductorController.logLines(controller.logs, filter: controller.logFilter, search: search)
    }

    private static let highlightTokens = ["outbound/chatgpt-vless", "outbound/direct", "inbound/tun", "FATAL", "ERROR"]

    private static func tokenColor(for token: String) -> Color {
        switch token {
        case "outbound/chatgpt-vless": .purple
        case "outbound/direct": .green
        case "inbound/tun": .blue
        case "FATAL": .red
        default: .orange
        }
    }
}

private struct RuntimeStatusBar: View {
    @ObservedObject var controller: ConductorController
    let showError: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Label(controller.displayStatusTitle, systemImage: controller.displayStatusSymbol).foregroundStyle(controller.status == .running ? .green : .primary)
            if let notice = controller.previousPIDNotice {
                Text(notice).foregroundStyle(.orange).lineLimit(1)
            } else if let error = controller.lastError {
                Button(error.split(separator: "\n").first.map(String.init) ?? error) { showError() }.buttonStyle(.link).lineLimit(1)
            } else if let message = controller.operationMessage {
                Text(message).foregroundStyle(.secondary).lineLimit(1)
            } else { Text(controller.routingSummary).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button(controller.isRunning ? "停止代理" : "启动代理") { Task { await controller.toggle() } }
                .buttonStyle(.borderedProminent).disabled(controller.isBusy)
        }.padding(.horizontal, 20).padding(.vertical, 12)
        .task(id: controller.operationMessage) {
            guard controller.operationMessage != nil else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            controller.clearOperationMessage()
        }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: ConductorController
    @State private var confirmingQuit = false

    var body: some View {
        Text(controller.displayStatusTitle)
        if let error = controller.lastError {
            Text(error.split(separator: "\n").first.map(String.init) ?? error)
                .foregroundStyle(.secondary).lineLimit(1)
        }
        Divider()
        Button(controller.isRunning ? "停止代理" : "启动代理") { Task { await controller.toggle() } }.disabled(controller.isBusy)
        Button(controller.isRunning ? "重新检查配置" : "检查配置") { Task { await controller.validateConfiguration() } }
            .disabled(controller.isBusy)
        Button("查看日志") { show(.logs) }.disabled(controller.logs.isEmpty)
        Button("代理出口") { show(.configuration) }
        Divider()
        Button("打开控制面板") { openControlPanel() }
        Button("打开配置") { controller.openControlPanel() }
        Divider()
        Button("退出") {
            if controller.isRunning { confirmingQuit = true } else { NSApplication.shared.terminate(nil) }
        }
        .alert("代理正在运行", isPresented: $confirmingQuit) {
            Button("取消", role: .cancel) {}
            Button("停止并退出", role: .destructive) {
                Task {
                    await controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
        } message: {
            Text("退出将先停止 sing-box。公司 VPN 与其他应用不受影响。")
        }
    }

    private func show(_ section: ControlSection) {
        controller.selectedSection = section
        openControlPanel()
    }

    private func openControlPanel() {
        openWindow(id: "control")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
