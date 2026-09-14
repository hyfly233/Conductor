import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: ConductorController
    @State private var section: ControlSection = .configuration
    @State private var editor: ConfigurationEditor?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Label("Conductor", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.weight(.semibold))
                Picker("页面", selection: $section) {
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
                switch section {
                case .configuration: ConfigurationPage(controller: controller, editor: $editor)
                case .companyVPN: CompanyVPNPage(controller: controller)
                case .settings: SettingsPage(controller: controller)
                case .logs: LogsPage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RuntimeStatusBar(controller: controller) { section = .logs }
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
    case vless, socks, http
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "配置", subtitle: "管理代理出口以及哪些流量使用它们") {
                    Menu {
                        Button("导入 VLESS URL…") { editor = .vless }
                        Button("添加 SOCKS5 出口…") { editor = .socks }
                        Button("添加 HTTP 出口…") { editor = .http }
                    } label: { Label("添加代理出口", systemImage: "plus") }
                    .disabled(controller.isRunning || controller.isBusy)
                }
                if controller.proxyConfigurations.isEmpty {
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
                Text("将删除“\(item.name)”及其流量绑定。若它是剩余流量出口，剩余流量将恢复直连。此操作会先备份当前配置。")
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
                    edit: { controller.openControlPanel() },
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
                Spacer()
                Label(item.health.rawValue, systemImage: item.health.symbol).font(.caption).foregroundStyle(healthColor)
            }
            Text(item.endpoint).font(.system(.body, design: .monospaced))
            HStack {
                Label(item.bindingSummary, systemImage: "arrow.triangle.branch").foregroundStyle(.secondary)
                Spacer()
                Button("测试", action: test).disabled(item.health == .checking)
                Button("编辑", action: edit).disabled(mutationDisabled).help("使用配置文件编辑高级字段")
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
}

private struct ConfigurationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: ConductorController
    let editor: ConfigurationEditor
    @State private var name = "vpn-proxy-01"
    @State private var endpoint: String
    @State private var domains = ""
    @State private var vlessURI = ""
    @State private var scope: ProxyRouteScope
    @State private var proxyKind: String
    @State private var selectedApplication: URL?
    @State private var excludedProcessPaths: [String] = []

    init(controller: ConductorController, editor: ConfigurationEditor) {
        self.controller = controller
        self.editor = editor
        _name = State(initialValue: "vpn-proxy-01")
        _endpoint = State(initialValue: editor == .vless ? "" : "127.0.0.1:7890")
        _scope = State(initialValue: editor == .vless ? .domains : .remaining)
        _proxyKind = State(initialValue: editor == .http ? "http" : "socks")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor == .vless ? "导入 VLESS Reality" : "添加代理出口").font(.title2.bold())
            if editor == .vless {
                TextField("粘贴 vless:// 地址", text: $vlessURI)
                LabeledContent("目标应用", value: "ChatGPT")
                Text("敏感参数不会显示在日志中。导入会更新 ChatGPT 应用和域名绑定。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("出口名称", text: $name)
                Picker("代理协议", selection: $proxyKind) {
                    Text("SOCKS5").tag("socks")
                    Text("HTTP").tag("http")
                }.pickerStyle(.segmented)
                TextField("IP/主机:端口", text: $endpoint)
                    .font(.system(.body, design: .monospaced))
                Picker("流量范围", selection: $scope) {
                    ForEach(ProxyRouteScope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if scope == .domains {
                    TextField("域名后缀，逗号分隔", text: $domains)
                } else {
                    Label("使用本机 VPN 代理时，其联网进程可能再次进入此出口并形成代理回环。请选择对应应用进行排除。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("选择本机 VPN 应用…") { chooseVPNApplication() }
                    if let selectedApplication {
                        Text(selectedApplication.lastPathComponent).foregroundStyle(.secondary)
                        Spacer()
                        Button("清除") {
                            self.selectedApplication = nil
                            excludedProcessPaths = []
                        }
                    }
                }
                if !excludedProcessPaths.isEmpty {
                    Label("将排除 \(excludedProcessPaths.count) 个联网进程，包括 \(excludedProcessPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))。", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.green)
                } else if isLocalEndpoint && scope == .remaining {
                    Text("尚未选择 VPN 应用。保存后可能出现代理回环。")
                        .font(.caption.bold()).foregroundStyle(.red)
                }
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(editor == .vless ? "导入" : "校验并保存") {
                    Task {
                        if editor == .vless { await controller.importVLESSURI(vlessURI, targetApp: "chatgpt") }
                        else {
                            await controller.saveProxy(
                                tag: name,
                                kind: proxyKind,
                                endpoint: endpoint,
                                domains: domains,
                                useAsDefault: scope == .remaining,
                                excludedProcessPaths: excludedProcessPaths
                            )
                        }
                        if controller.lastError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(!isValid || controller.isBusy)
            }
        }.padding(24).frame(width: 560)
    }

    private var isValid: Bool {
        if editor == .vless { return vlessURI.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("vless://") }
        let endpointValid = !name.isEmpty && endpoint.contains(":")
        return endpointValid && (scope == .remaining || !domains.isEmpty)
    }

    private var isLocalEndpoint: Bool {
        endpoint.hasPrefix("127.") || endpoint.hasPrefix("localhost:") || endpoint.hasPrefix("[::1]:")
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
}

private struct CompanyVPNPage: View {
    @ObservedObject var controller: ConductorController
    @State private var evidence: CompanyVPNObservation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "公司 VPN", subtitle: "只检测客户端、接口和公司网段，不控制 VPN 连接") {
                    Button { Task { await controller.inspectCompanyVPNs() } } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                }
                ForEach(controller.companyVPNs) { vpn in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(vpn.name).font(.headline); Spacer()
                            Text(vpn.state.rawValue).foregroundStyle(vpn.state == .connected ? .green : .secondary)
                        }
                        LabeledContent("当前接口", value: vpn.interfaceName ?? "未确认")
                        LabeledContent("公司网段", value: vpn.networks.joined(separator: "、"))
                        HStack {
                            if let date = vpn.checkedAt { Text("检查于 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("查看路由证据") { evidence = vpn }
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
                        HStack { Spacer(); Button("检查 sing-box") { Task { await controller.checkRuntime(); await controller.validateConfiguration() } } }
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
                                    Text(item.createdAt.formatted(date: .numeric, time: .shortened))
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
            Text("将先备份当前配置，再恢复所选版本。")
        }
    }
}

private struct LogsPage: View {
    @ObservedObject var controller: ConductorController
    @State private var filter: LogFilter = .all
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日志").font(.title.bold())
                Picker("筛选", selection: $filter) { ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                TextField("搜索日志", text: $search).textFieldStyle(.roundedBorder)
                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(filteredLogs, forType: .string) }
                Menu {
                    Button("清空当前显示") { controller.clearDisplayedLogs() }
                    Button("打开日志目录") { controller.openLogFile() }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(24)
            Divider()
            ScrollView {
                Text(filteredLogs.isEmpty ? "启动代理后将在这里显示日志。" : filteredLogs)
                    .frame(maxWidth: .infinity, alignment: .leading).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).padding(20)
            }
        }
    }

    private var filteredLogs: String {
        controller.logs.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            let categoryMatch: Bool = switch filter {
            case .all: true
            case .vless: line.localizedCaseInsensitiveContains("vless") || line.localizedCaseInsensitiveContains("openai")
            case .localProxy: line.localizedCaseInsensitiveContains("socks") || line.localizedCaseInsensitiveContains("http")
            case .companyVPN: line.localizedCaseInsensitiveContains("utun") || line.localizedCaseInsensitiveContains("vpn")
            case .direct: line.localizedCaseInsensitiveContains("direct")
            case .errors: line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("fatal") || line.localizedCaseInsensitiveContains("warning")
            }
            return categoryMatch && (search.isEmpty || line.localizedCaseInsensitiveContains(search))
        }.joined(separator: "\n")
    }
}

private struct RuntimeStatusBar: View {
    @ObservedObject var controller: ConductorController
    let showError: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Label(controller.status.title, systemImage: controller.status.symbolName).foregroundStyle(controller.status == .running ? .green : .primary)
            if let error = controller.lastError {
                Button(error.split(separator: "\n").first.map(String.init) ?? error) { showError() }.buttonStyle(.link).lineLimit(1)
            } else { Text("ChatGPT → VPS").foregroundStyle(.secondary) }
            Spacer()
            Button(controller.isRunning ? "停止代理" : "启动代理") { Task { await controller.toggle() } }
                .buttonStyle(.borderedProminent).disabled(controller.isBusy)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: ConductorController

    var body: some View {
        Text(controller.status.title)
        Divider()
        Button(controller.isRunning ? "停止代理" : "启动代理") { Task { await controller.toggle() } }.disabled(controller.isBusy)
        Button("检查配置") { Task { await controller.validateConfiguration() } }.disabled(controller.isBusy)
        Button("打开控制面板") { openWindow(id: "control"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Button("打开配置") { controller.openControlPanel() }
        Divider()
        Button("退出") { controller.stop(); NSApplication.shared.terminate(nil) }
    }
}
