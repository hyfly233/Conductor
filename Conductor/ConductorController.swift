import AppKit
import Combine
import Darwin
import Foundation

enum ConductorStatus: Equatable {
    case stopped, validating, starting, running, stopping, configurationError, failed

    var title: String {
        switch self {
        case .stopped: "代理未运行"
        case .validating: "正在检查配置…"
        case .starting: "正在启动…"
        case .running: "代理运行中"
        case .stopping: "正在停止…"
        case .configurationError: "配置错误"
        case .failed: "运行异常"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "checkmark.shield.fill"
        case .validating, .starting, .stopping: "arrow.triangle.2.circlepath"
        case .configurationError, .failed: "exclamationmark.triangle.fill"
        case .stopped: "shield.slash"
        }
    }
}

@MainActor
final class ConductorController: ObservableObject {
    @Published private(set) var status: ConductorStatus = .stopped
    @Published private(set) var logs = ""
    @Published private(set) var lastError: String?
    @Published private(set) var proxyConfigurations: [ProxyConfiguration] = []
    @Published private(set) var companyVPNs: [CompanyVPNObservation] = []
    @Published private(set) var configurationHistory: [ConfigurationHistoryItem] = []
    @Published private(set) var runtimeVersion = "未检查"
    @Published private(set) var runtimeHealth: HealthState = .unknown
    @Published private(set) var routingSummary = "尚未读取配置"
    @Published private(set) var operationMessage: String?
    @Published private(set) var configurationReadError: String?

    @Published var selectedSection: ControlSection = .configuration
    @Published var logFilter: LogFilter = .all

    private var privilegedPID: Int32?
    private var logMonitorTask: Task<Void, Never>?
    private var lastRuntimeLog = ""
    private var clearedRuntimeLogPrefix = ""
    private let proxyExclusionsDefaultsKey = "proxyExcludedProcessPaths"
    private let mixedProxyTagsDefaultsKey = "mixedProxyTags"
    private let tcpOnlyDefaultTagsDefaultsKey = "tcpOnlyDefaultProxyTags"
    let configPath: String
    private let pidFileURL: URL
    @Published private(set) var singBoxPath: String

    func selectDevelopmentRuntime() async {
#if DEBUG
        guard !isRunning, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 sing-box 可执行文件（不低于 \(Self.minimumSupportedRuntimeVersion)）"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            fail("所选文件不可执行")
            return
        }
        status = .validating
        do {
            let result = try await runSystemProcess(executable: url.path, arguments: ["version"])
            let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? "未知版本"
            let version = firstLine.replacingOccurrences(of: "sing-box version ", with: "")
            guard result.status == 0, Self.isSupportedSingBoxVersion(version) else {
                throw ConductorError.commandFailed("请选择不低于 \(Self.minimumSupportedRuntimeVersion) 的 sing-box，当前运行时未改变")
            }
            singBoxPath = url.path
            runtimeVersion = version
            runtimeHealth = .healthy
            lastError = nil
            status = .stopped
            operationMessage = "已选择开发运行时，仅本次会话生效"
        } catch { fail(error.localizedDescription) }
#endif
    }

    init(configPath: String = "\(NSHomeDirectory())/sing-box/config.json", singBoxPath: String? = nil, pidFileURL: URL? = nil) {
        self.configPath = configPath
        self.pidFileURL = pidFileURL ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/Conductor/sing-box.pid")
        self.singBoxPath = singBoxPath ?? Self.findSingBox()
        reloadConfigurationSummary()
        reloadHistory()
        companyVPNs = Self.defaultCompanyVPNs
        if let pid = Self.livePID(in: self.pidFileURL) {
            lastError = Self.previousPIDWarning(pid)
            status = .failed
        }
    }

    var isRunning: Bool {
        privilegedPID.map(isProcessRunning) == true
    }
    var isBusy: Bool {
        switch status {
        case .validating, .starting, .stopping: true
        default: false
        }
    }

    var previousPIDNotice: String? {
        guard !isRunning, let pid = Self.livePID(in: pidFileURL) else { return nil }
        return Self.previousPIDWarning(pid)
    }
    var displayStatusTitle: String { previousPIDNotice == nil ? status.title : "上次进程未确认" }
    var displayStatusSymbol: String { previousPIDNotice == nil ? status.symbolName : "exclamationmark.triangle.fill" }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    func start() async {
        guard !isBusy, !isRunning else { return }
        if let pid = Self.livePID(in: pidFileURL) {
            lastError = Self.previousPIDWarning(pid)
            status = .failed
            return
        }
        guard FileManager.default.isExecutableFile(atPath: singBoxPath) else {
            fail("找不到 sing-box：\(singBoxPath)")
            return
        }
        status = .validating
        do {
            try await requireSupportedRuntime()
            try await runCheck()
            status = .starting
            await launchProcess()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func validateConfiguration() async {
        guard !isBusy else { return }
        status = .validating
        do {
            try await runCheck()
            lastError = nil
            status = isRunning ? .running : .stopped
            operationMessage = "配置检查通过"
            appendLog("sing-box 配置检查通过。\n")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard let privilegedPID else {
            status = .stopped
            return
        }
        status = .stopping
        await stopPrivilegedProcess(pid: privilegedPID)
    }

    func refreshStatus() {
        if privilegedPID.map(isProcessRunning) == true {
            if status != .stopping { status = .running }
        } else if status == .running || status == .stopping {
            privilegedPID = nil
            status = .stopped
        }
    }

    func openControlPanel() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    func openLogFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/Conductor"))
    }

    func openConfigDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath).deletingLastPathComponent())
    }

    func clearDisplayedLogs() {
        clearedRuntimeLogPrefix = lastRuntimeLog
        logs = ""
    }

    func clearOperationMessage() {
        operationMessage = nil
    }

    func clearError(ifMatching message: String?) {
        if let message, lastError == message { lastError = nil }
    }

    static let minimumSupportedRuntimeVersion = "1.14.0"

    static func isSupportedSingBoxVersion(_ version: String) -> Bool {
        guard let candidate = versionNumbers(version), let floor = versionNumbers(minimumSupportedRuntimeVersion) else { return false }
        let count = max(candidate.count, floor.count)
        for index in 0..<count {
            let lhs = index < candidate.count ? candidate[index] : 0
            let rhs = index < floor.count ? floor[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func versionNumbers(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    func checkRuntime() async {
        guard runtimeHealth != .checking else { return }
        runtimeHealth = .checking
        do {
            let result = try await runProcess(arguments: ["version"])
            let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? "未知版本"
            runtimeVersion = firstLine.replacingOccurrences(of: "sing-box version ", with: "")
            runtimeHealth = result.status == 0 && Self.isSupportedSingBoxVersion(runtimeVersion) ? .healthy : .warning
            appendLog("\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))\n")
            if runtimeHealth == .warning {
                let message = "当前 sing-box 为 \(runtimeVersion)，低于 Conductor 1.0 要求的最低版本 \(Self.minimumSupportedRuntimeVersion)"
                lastError = message
                appendLog("ERROR \(message)\n")
            } else {
                lastError = nil
            }
        } catch {
            runtimeVersion = "不可用"
            runtimeHealth = .failed
            lastError = error.localizedDescription
            appendLog("ERROR \(error.localizedDescription)\n")
        }
        if !isRunning, let pid = Self.livePID(in: pidFileURL) {
            lastError = Self.previousPIDWarning(pid)
            status = .failed
        }
    }

    func inspectCompanyVPNs() async {
        let definitions = Self.defaultCompanyVPNs
        var observations: [CompanyVPNObservation] = []
        for definition in definitions {
            var item = definition
            let processResult = try? await runSystemProcess(
                executable: "/usr/bin/pgrep",
                arguments: ["-ifl", definition.processPattern]
            )
            var evidence: [String] = []
            var detectedInterfaces: Set<String> = []
            var routeChecksSucceeded = 0
            for network in definition.networks {
                let target = network.split(separator: "/").first.map(String.init) ?? network
                if let route = try? await runSystemProcess(executable: "/sbin/route", arguments: ["-n", "get", target]), route.status == 0 {
                    routeChecksSucceeded += 1
                    evidence.append(route.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let line = route.output.split(separator: "\n").first(where: { $0.contains("interface:") }) {
                        if let name = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), name.hasPrefix("utun") {
                            detectedInterfaces.insert(name)
                        }
                    }
                }
            }
            item.interfaceName = detectedInterfaces.count == 1 ? detectedInterfaces.first : nil
            item.state = Self.companyVPNState(processStatus: processResult?.status, hasTunnelRoute: !detectedInterfaces.isEmpty, routesChecked: routeChecksSucceeded == definition.networks.count)
            item.evidence = evidence.isEmpty ? (processResult?.output ?? "未发现客户端进程或路由证据") : evidence.joined(separator: "\n\n")
            item.checkedAt = Date()
            observations.append(item)
        }
        companyVPNs = observations
    }

    static func companyVPNState(processStatus: Int32?, hasTunnelRoute: Bool, routesChecked: Bool = true) -> CompanyVPNState {
        guard let processStatus, processStatus == 0 || processStatus == 1 else { return .failed }
        guard routesChecked else { return .uncertain }
        return processStatus == 1 && !hasTunnelRoute ? .disconnected : .uncertain
    }

    func tunExclusions() -> (values: [String], snapshot: Data)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = config["inbounds"] as? [[String: Any]] else { return nil }
        let tunnels = inbounds.filter { $0["type"] as? String == "tun" }
        guard tunnels.count == 1, tunnels[0]["auto_route"] as? Bool == true else { return nil }
        let values: [String]
        switch tunnels[0]["route_exclude_address"] {
        case nil: values = []
        case let list as [String]: values = list
        case let single as String: values = [single]
        default: return nil
        }
        return (values, data)
    }

    static func isValidCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let address = String(parts[0])
        if inet_pton(AF_INET, address, &ipv4) == 1 { return (0...32).contains(prefix) }
        if inet_pton(AF_INET6, address, &ipv6) == 1 { return (0...128).contains(prefix) }
        return false
    }

    static func normalizedIPOrCIDR(_ value: String) -> String? {
        if isValidCIDR(value) { return value }
        guard !value.contains("/") else { return nil }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 { return value + "/32" }
        if inet_pton(AF_INET6, value, &ipv6) == 1 { return value + "/128" }
        return nil
    }

    static func cidr(_ target: String, isCoveredBy exclusion: String) -> Bool {
        func parse(_ value: String) -> (bytes: [UInt8], prefix: Int)? {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            let address = String(parts[0])
            var ipv4 = in_addr(), ipv6 = in6_addr()
            if inet_pton(AF_INET, address, &ipv4) == 1, (0...32).contains(prefix) {
                return (withUnsafeBytes(of: &ipv4) { Array($0) }, prefix)
            }
            if inet_pton(AF_INET6, address, &ipv6) == 1, (0...128).contains(prefix) {
                return (withUnsafeBytes(of: &ipv6) { Array($0) }, prefix)
            }
            return nil
        }
        guard let target = parse(target), let exclusion = parse(exclusion),
              target.bytes.count == exclusion.bytes.count, target.prefix >= exclusion.prefix else { return false }
        let fullBytes = exclusion.prefix / 8
        guard target.bytes.prefix(fullBytes).elementsEqual(exclusion.bytes.prefix(fullBytes)) else { return false }
        let remaining = exclusion.prefix % 8
        guard remaining > 0 else { return true }
        let mask = UInt8(0xff << (8 - remaining) & 0xff)
        return target.bytes[fullBytes] & mask == exclusion.bytes[fullBytes] & mask
    }

    func saveTUNExclusions(_ values: [String], expectedConfig: Data) async {
        guard !isRunning, !isBusy else { return }
        guard values.allSatisfy(Self.isValidCIDR), Set(values).count == values.count else {
            failTUNExclusions("请输入有效且不重复的 CIDR 网段")
            return
        }
        status = .validating
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let url = URL(fileURLWithPath: configPath)
            let original = try Data(contentsOf: url)
            guard original == expectedConfig else { throw ConductorError.operationFailed("配置已变化，请关闭窗口并重新编辑") }
            guard var config = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  var inbounds = config["inbounds"] as? [[String: Any]] else { throw ConductorError.operationFailed("无法读取 TUN 配置") }
            let indexes = inbounds.indices.filter { inbounds[$0]["type"] as? String == "tun" }
            guard indexes.count == 1, inbounds[indexes[0]]["auto_route"] as? Bool == true else {
                throw ConductorError.operationFailed("需要一个启用 auto_route 的 TUN 入站")
            }
            if values.isEmpty { inbounds[indexes[0]].removeValue(forKey: "route_exclude_address") }
            else { inbounds[indexes[0]]["route_exclude_address"] = values }
            config["inbounds"] = inbounds
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try Self.writePrivateTemporary(data, to: temporary)
            let result = try await runProcess(arguments: ["check", "-c", temporary.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            guard try Data(contentsOf: url) == original else { throw ConductorError.operationFailed("检查期间配置已变化，请关闭窗口并重新编辑") }
            let backup = url.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastError = nil
            status = .stopped
            operationMessage = "TUN 排除网段已保存，下次启动时生效"
            appendLog("TUN 排除网段已更新，原配置已备份。\n")
            reloadHistory()
        } catch { failTUNExclusions(error.localizedDescription) }
    }

    private func failTUNExclusions(_ message: String) {
        lastError = message
        operationMessage = nil
        appendLog("\(message)\n")
        status = isRunning ? .running : .stopped
    }

    func reloadConfigurationSummary() {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            proxyConfigurations = []
            routingSummary = "配置不可读取"
            configurationReadError = FileManager.default.fileExists(atPath: configPath)
                ? "无法读取配置或 JSON 格式无效，请打开文件检查。"
                : "配置文件尚不存在，请先准备 sing-box 配置文件。"
            return
        }
        configurationReadError = nil
        let route = config["route"] as? [String: Any] ?? [:]
        let rules = route["rules"] as? [[String: Any]] ?? []
        let defaultOutbound = route["final"] as? String
        routingSummary = "剩余流量 → \(defaultOutbound == "direct" ? "直连" : (defaultOutbound ?? "默认出口"))"
        proxyConfigurations = (config["outbounds"] as? [[String: Any]] ?? []).compactMap { outbound in
            guard let type = outbound["type"] as? String,
                  ["vless", "socks", "http"].contains(type),
                  let tag = outbound["tag"] as? String else { return nil }
            let host = outbound["server"] as? String ?? "未配置"
            let port = outbound["server_port"] as? Int
            let displayHost = Self.maskHost(host)
            let endpoint = port.map { "\(displayHost.contains(":") ? "[\(displayHost)]" : displayHost):\($0)" } ?? displayHost
            var bindings: [String] = []
            if defaultOutbound == tag { bindings.append("剩余流量") }
            for rule in rules where rule["outbound"] as? String == tag {
                if rule["process_name"] != nil || rule["process_path"] != nil { bindings.append("应用") }
                let domains = Self.stringValues(rule["domain_suffix"])
                if !domains.isEmpty {
                    bindings.append(domains.prefix(2).joined(separator: "、") + (domains.count > 2 ? " 等域名" : ""))
                }
                if rule["ip_cidr"] != nil { bindings.append("IP/CIDR") }
            }
            var sourceParts: [String] = []
            if stringSet(forKey: mixedProxyTagsDefaultsKey).contains(tag) { sourceParts.append("由混合端口探测") }
            if stringSet(forKey: tcpOnlyDefaultTagsDefaultsKey).contains(tag) { sourceParts.append("仅 TCP") }
            return ProxyConfiguration(
                id: tag,
                type: type.uppercased(),
                name: tag == "chatgpt-vless" ? "VPS" : tag,
                endpoint: endpoint,
                bindingSummary: bindings.isEmpty ? "未绑定流量" : Array(Set(bindings)).joined(separator: " · "),
                sourceSummary: sourceParts.isEmpty ? nil : sourceParts.joined(separator: " · ")
            )
        }
    }

    func proxyEditorValues(tag: String) -> (endpoint: String, domains: String, cidrs: String, applications: [String], isDefault: Bool, paths: [String], username: String, password: String)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbound = (config["outbounds"] as? [[String: Any]])?.first(where: { $0["tag"] as? String == tag }),
              let host = outbound["server"] as? String,
              let port = outbound["server_port"] as? Int else { return nil }
        let route = config["route"] as? [String: Any] ?? [:]
        let domains = (route["rules"] as? [[String: Any]] ?? []).filter {
            $0["outbound"] as? String == tag && Set($0.keys).isSubset(of: ["outbound", "domain_suffix", "action"])
        }
            .flatMap { Self.stringValues($0["domain_suffix"]) }
        let cidrs = (route["rules"] as? [[String: Any]] ?? []).filter {
            $0["outbound"] as? String == tag && $0["ip_cidr"] != nil && Set($0.keys).isSubset(of: ["outbound", "ip_cidr", "action"])
        }.flatMap { rule -> [String] in
            if let values = rule["ip_cidr"] as? [String] { return values }
            return (rule["ip_cidr"] as? String).map { [$0] } ?? []
        }
        let applications = (route["rules"] as? [[String: Any]] ?? []).filter {
            $0["outbound"] as? String == tag && $0["process_path"] != nil && Set($0.keys).isSubset(of: ["outbound", "process_path", "action"])
        }.flatMap { rule -> [String] in
            if let values = rule["process_path"] as? [String] { return values }
            return (rule["process_path"] as? String).map { [$0] } ?? []
        }
        return ("\(host.contains(":") ? "[\(host)]" : host):\(port)", domains.joined(separator: ", "), cidrs.joined(separator: ", "), applications, route["final"] as? String == tag, managedExcludedProcessPaths(for: tag), outbound["username"] as? String ?? "", outbound["password"] as? String ?? "")
    }

    func usesMixedProxyDetection(tag: String) -> Bool {
        stringSet(forKey: mixedProxyTagsDefaultsKey).contains(tag)
    }

    private static func stringValues(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        return (value as? String).map { [$0] } ?? []
    }

    var nextProxyTag: String {
        let data = try? Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let outbounds = config?["outbounds"] as? [[String: Any]] ?? []
        let existing = Set(outbounds.compactMap { $0["tag"] as? String })
        var index = 1
        while existing.contains(String(format: "vpn-proxy-%02d", index)) { index += 1 }
        return String(format: "vpn-proxy-%02d", index)
    }

    func existingOutboundType(tag: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = config["outbounds"] as? [[String: Any]] else { return nil }
        return outbounds.first { $0["tag"] as? String == tag }?["type"] as? String
    }

    func dnsUsesOutbound(tag: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dns = config["dns"] as? [String: Any],
              let servers = dns["servers"] as? [[String: Any]] else { return false }
        return servers.contains { $0["detour"] as? String == tag }
    }

    func probeMixedProxy(endpoint: String, username: String = "", password: String = "") async -> MixedProxyProbeResult {
        guard let parsed = Self.parseEndpoint(endpoint) else {
            fail("请输入有效的 IP/主机:端口")
            return MixedProxyProbeResult(httpAvailable: false, socksTCPAvailable: false, socksUDPAvailable: false)
        }
        appendLog("正在探测混合端口 \(endpoint)…\n")
        let httpProbe = Task.detached(priority: .userInitiated) {
            Self.probeHTTPConnect(host: parsed.host, port: parsed.port, username: username, password: password)
        }
        let result = await Task.detached(priority: .userInitiated) {
            let socksTCP = Self.probeSOCKS5(host: parsed.host, port: parsed.port, command: 0x01, username: username, password: password)
            let socksUDP = socksTCP && Self.probeSOCKS5(host: parsed.host, port: parsed.port, command: 0x03, username: username, password: password)
            let http = await httpProbe.value
            return MixedProxyProbeResult(httpAvailable: http, socksTCPAvailable: socksTCP, socksUDPAvailable: socksUDP)
        }.value
        let selected = result.selectedKind?.uppercased() ?? "无可用协议"
        appendLog("混合端口探测完成：HTTP \(result.httpAvailable ? "成功" : "失败")，SOCKS5 TCP \(result.socksTCPAvailable ? "成功" : "失败")，SOCKS5 UDP 握手 \(result.socksUDPAvailable ? "已接受（数据转发未验证）" : "失败")；选择 \(selected)。\n")
        return result
    }

    func localListenerNames(endpoint: String) async -> [String]? {
        guard let endpoint = Self.parseEndpoint(endpoint),
              endpoint.host.hasPrefix("127.") || ["localhost", "::1"].contains(endpoint.host) else { return nil }
        guard let result = try? await runSystemProcess(executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(endpoint.port)", "-sTCP:LISTEN", "-Fc"]), result.status == 0 else { return nil }
        let names = result.output.split(separator: "\n").filter { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
        return names.isEmpty ? nil : Array(Set(names)).sorted()
    }

    func testProxyConfiguration(id: String) async {
        guard let index = proxyConfigurations.firstIndex(where: { $0.id == id }) else { return }
        proxyConfigurations[index].health = .checking
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbound = (config["outbounds"] as? [[String: Any]])?.first(where: { $0["tag"] as? String == id }),
              let host = outbound["server"] as? String,
              let port = outbound["server_port"] as? Int else {
            proxyConfigurations[index].health = .failed
            return
        }
        let result = try? await runSystemProcess(executable: "/usr/bin/nc", arguments: ["-z", "-w", "5", host, String(port)])
        guard let refreshedIndex = proxyConfigurations.firstIndex(where: { $0.id == id }) else { return }
        proxyConfigurations[refreshedIndex].health = result?.status == 0 ? .healthy : .failed
        appendLog("出口 \(id) TCP 连通性测试：\(result?.status == 0 ? "成功" : "失败")。\n")
    }

    func deleteProxyConfiguration(id: String) async {
        guard !isBusy, !isRunning else { return }
        status = .validating
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let url = URL(fileURLWithPath: configPath)
            let original = try Data(contentsOf: url)
            guard var config = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw ConductorError.commandFailed("配置必须是 JSON 对象")
            }
            var outbounds = config["outbounds"] as? [[String: Any]] ?? []
            guard outbounds.contains(where: { $0["tag"] as? String == id }) else {
                throw ConductorError.commandFailed("找不到出口：\(id)")
            }
            outbounds.removeAll { $0["tag"] as? String == id }
            config["outbounds"] = outbounds

            var route = config["route"] as? [String: Any] ?? [:]
            var rules = route["rules"] as? [[String: Any]] ?? []
            rules.removeAll { $0["outbound"] as? String == id }
            let managedPaths = managedExcludedProcessPaths(for: id)
            if !managedPaths.isEmpty {
                let managedNames = managedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                rules.removeAll { rule in
                    guard rule["outbound"] as? String == "direct" else { return false }
                    if let paths = rule["process_path"] as? [String] { return Set(paths) == Set(managedPaths) }
                    if let names = rule["process_name"] as? [String] { return Set(names) == Set(managedNames) }
                    return false
                }
            }
            route["rules"] = rules
            if route["final"] as? String == id { route["final"] = "direct" }
            if stringSet(forKey: tcpOnlyDefaultTagsDefaultsKey).contains(id) {
                Self.removeManagedUDP443RejectRule(from: &rules)
                route["rules"] = rules
            }
            config["route"] = route

            if var dns = config["dns"] as? [String: Any],
               var servers = dns["servers"] as? [[String: Any]] {
                for index in servers.indices where servers[index]["detour"] as? String == id {
                    servers[index].removeValue(forKey: "detour")
                }
                dns["servers"] = servers
                config["dns"] = dns
            }

            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try Self.writePrivateTemporary(data, to: temporary)
            let result = try await runProcess(arguments: ["check", "-c", temporary.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            guard try Data(contentsOf: url) == original else {
                throw ConductorError.commandFailed("配置已被外部修改，请重试")
            }
            let backup = url.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            setManagedExcludedProcessPaths([], for: id)
            setMembership(false, tag: id, key: mixedProxyTagsDefaultsKey)
            setMembership(false, tag: id, key: tcpOnlyDefaultTagsDefaultsKey)
            appendLog("已删除出口 \(id) 及其流量绑定，原配置已备份。\n")
            operationMessage = "已删除出口，原配置可从历史记录恢复"
            reloadConfigurationSummary()
            reloadHistory()
            lastError = nil
            status = .stopped
        } catch { fail(error.localizedDescription) }
    }

    func reloadHistory() {
        let configURL = URL(fileURLWithPath: configPath)
        let directory = configURL.deletingLastPathComponent()
        let prefix = configURL.lastPathComponent + ".backup-"
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        configurationHistory = urls.filter { $0.lastPathComponent.hasPrefix(prefix) }.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let reason = url.lastPathComponent.hasPrefix(prefix + "restore-") ? "恢复前备份" : "配置变更备份"
            return ConfigurationHistoryItem(id: url.path, url: url, createdAt: date, reason: reason)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restoreHistory(_ item: ConfigurationHistoryItem) async {
        guard !isRunning, !isBusy else { return }
        status = .validating
        do {
            let data = try Data(contentsOf: item.url)
            let current = URL(fileURLWithPath: configPath)
            let original = try Data(contentsOf: current)
            let result = try await runProcess(arguments: ["check", "-c", item.url.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            guard try Data(contentsOf: item.url) == data, try Data(contentsOf: current) == original else {
                throw ConductorError.commandFailed("检查期间配置已变化，请重新选择历史配置")
            }
            if FileManager.default.fileExists(atPath: current.path) {
                let backup = current.appendingPathExtension("backup-restore-" + UUID().uuidString)
                try FileManager.default.copyItem(at: current, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            try data.write(to: current, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            reloadConfigurationSummary()
            reloadHistory()
            status = .stopped
            lastError = nil
            appendLog("历史配置已恢复，并已备份恢复前配置。\n")
            operationMessage = "历史配置已恢复，恢复前配置已备份"
        } catch { fail(error.localizedDescription) }
    }

    func saveProxy(
        tag: String,
        kind: String,
        endpoint: String,
        domains: String,
        useAsDefault: Bool,
        excludedProcessPaths: [String],
        supportsUDP: Bool,
        wasAutoDetected: Bool,
        credentials: (username: String, password: String)? = nil,
        requireNew: Bool = false,
        expectedConfig: Data? = nil,
        destinationCIDRs: [String]? = nil,
        destinationAppPaths: [String]? = nil
    ) async {
        guard !isBusy, !isRunning else { return }
        let parsedEndpoint = Self.parseEndpoint(endpoint)
        guard !tag.isEmpty, !["direct", "chatgpt-vless"].contains(tag),
              let parsedEndpoint,
              ["socks", "http"].contains(kind) else {
            fail("请输入独立出口名称和有效的 IP/主机:端口")
            return
        }
        status = .validating
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let url = URL(fileURLWithPath: configPath)
            let original = try Data(contentsOf: url)
            if let expectedConfig, original != expectedConfig {
                throw ConductorError.commandFailed("配置在打开编辑窗口后已发生变化，请关闭窗口并重新编辑")
            }
            guard var config = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw ConductorError.commandFailed("配置必须是 JSON 对象")
            }
            var outbounds = config["outbounds"] as? [[String: Any]] ?? []
            if requireNew && outbounds.contains(where: { $0["tag"] as? String == tag }) {
                throw ConductorError.commandFailed("出口名称已存在，请更换名称或编辑已有出口")
            }
            let newOutbound: [String: Any] = ["type": kind, "tag": tag, "server": parsedEndpoint.host, "server_port": parsedEndpoint.port]
            if let existingIndex = outbounds.firstIndex(where: { $0["tag"] as? String == tag }) {
                guard let existingType = outbounds[existingIndex]["type"] as? String, ["http", "socks"].contains(existingType) else {
                    throw ConductorError.commandFailed("出口名称已被其他类型使用，请更换名称")
                }
                outbounds[existingIndex].merge(newOutbound) { _, new in new }
                if kind == "http" { outbounds[existingIndex].removeValue(forKey: "version") }
            } else {
                outbounds.append(newOutbound)
            }
            if let credentials, let index = outbounds.firstIndex(where: { $0["tag"] as? String == tag }) {
                if credentials.username.isEmpty && credentials.password.isEmpty {
                    outbounds[index].removeValue(forKey: "username")
                    outbounds[index].removeValue(forKey: "password")
                } else {
                    outbounds[index]["username"] = credentials.username
                    outbounds[index]["password"] = credentials.password
                }
            }
            config["outbounds"] = outbounds
            var route = config["route"] as? [String: Any] ?? [:]
            var rules = route["rules"] as? [[String: Any]] ?? []
            if !useAsDefault && destinationCIDRs == nil && destinationAppPaths == nil { rules.removeAll { rule in
                rule["outbound"] as? String == tag && rule["domain_suffix"] != nil &&
                    Set(rule.keys).isSubset(of: ["outbound", "domain_suffix", "action"])
            } } else if !useAsDefault && destinationCIDRs != nil { rules.removeAll { rule in
                rule["outbound"] as? String == tag && rule["ip_cidr"] != nil &&
                    Set(rule.keys).isSubset(of: ["outbound", "ip_cidr", "action"])
            } } else if !useAsDefault && destinationAppPaths != nil { rules.removeAll { rule in
                rule["outbound"] as? String == tag && rule["process_path"] != nil &&
                    Set(rule.keys).isSubset(of: ["outbound", "process_path", "action"])
            } }
            let managedTCPOnlyDefaults = stringSet(forKey: tcpOnlyDefaultTagsDefaultsKey)
            if managedTCPOnlyDefaults.contains(tag) || (useAsDefault && !managedTCPOnlyDefaults.isEmpty) {
                Self.removeManagedUDP443RejectRule(from: &rules)
            }
            let previousManagedPaths = managedExcludedProcessPaths(for: tag)
            if !previousManagedPaths.isEmpty {
                let previousManagedNames = previousManagedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                rules.removeAll { rule in
                    guard rule["outbound"] as? String == "direct" else { return false }
                    if let rulePaths = rule["process_path"] as? [String] { return Set(rulePaths) == Set(previousManagedPaths) }
                    if let ruleNames = rule["process_name"] as? [String] { return Set(ruleNames) == Set(previousManagedNames) }
                    return false
                }
            }
            let paths = Array(Set(excludedProcessPaths)).sorted()
            if !paths.isEmpty {
                route["find_process"] = true
                let names = Array(Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })).sorted()
                rules.insert(contentsOf: [
                    ["process_path": paths, "action": "route", "outbound": "direct"],
                    ["process_name": names, "action": "route", "outbound": "direct"]
                ], at: 0)
            }
            if useAsDefault {
                route["final"] = tag
                if !supportsUDP {
                    rules.append(["network": "udp", "port": 443, "action": "reject"])
                }
            } else {
                if route["final"] as? String == tag { route["final"] = "direct" }
                if let destinationAppPaths {
                    let selectedPaths = Array(Set(destinationAppPaths)).sorted()
                    guard (!selectedPaths.isEmpty || !requireNew), selectedPaths.allSatisfy({ $0.hasPrefix("/") }), Set(selectedPaths).isDisjoint(with: Set(paths)) else {
                        throw ConductorError.operationFailed("请选择有效应用，且不能与代理防回环进程重复")
                    }
                    if !selectedPaths.isEmpty {
                        route["find_process"] = true
                        let index = rules.firstIndex(where: Self.isManagedUDP443RejectRule) ?? rules.endIndex
                        rules.insert(["process_path": selectedPaths, "action": "route", "outbound": tag], at: index)
                    }
                } else if let destinationCIDRs {
                    let cidrs = destinationCIDRs.compactMap(Self.normalizedIPOrCIDR)
                    guard (!cidrs.isEmpty || !requireNew), cidrs.count == destinationCIDRs.count, Set(cidrs).count == cidrs.count else {
                        throw ConductorError.operationFailed("请输入有效且不重复的 IP/CIDR")
                    }
                    if !cidrs.isEmpty {
                        let index = rules.firstIndex(where: Self.isManagedUDP443RejectRule) ?? rules.endIndex
                        rules.insert(["ip_cidr": cidrs, "action": "route", "outbound": tag], at: index)
                    }
                } else {
                    let suffixes = domains.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                    guard !suffixes.isEmpty || !requireNew else { throw ConductorError.commandFailed("请填写至少一个域名后缀") }
                    if !suffixes.isEmpty {
                        let index = rules.firstIndex { $0["domain_suffix"] != nil } ?? rules.endIndex
                        rules.insert(["domain_suffix": suffixes, "action": "route", "outbound": tag], at: index)
                    }
                }
            }
            route["rules"] = rules
            config["route"] = route
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try Self.writePrivateTemporary(data, to: temporary)
            let result = try await runProcess(arguments: ["check", "-c", temporary.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            guard try Data(contentsOf: url) == original else { throw ConductorError.commandFailed("配置已被外部修改，请重试") }
            let backup = url.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            setManagedExcludedProcessPaths(paths, for: tag)
            setMembership(wasAutoDetected, tag: tag, key: mixedProxyTagsDefaultsKey)
            if useAsDefault {
                UserDefaults.standard.set(supportsUDP ? [] : [tag], forKey: tcpOnlyDefaultTagsDefaultsKey)
            } else {
                setMembership(false, tag: tag, key: tcpOnlyDefaultTagsDefaultsKey)
            }
            let exclusionText = paths.isEmpty ? "" : "，已排除 \(paths.count) 个 VPN 应用进程以避免代理回环"
            appendLog("已保存出口 \(tag)\(useAsDefault ? "，剩余流量将使用该出口" : "")\(exclusionText)，原配置已备份。端口实际连通性尚未验证。\n")
            operationMessage = "配置已保存，下次启动代理时生效"
            reloadConfigurationSummary()
            reloadHistory()
            lastError = nil
            status = .stopped
        } catch { fail(error.localizedDescription) }
    }

    func importVLESSURI(_ input: String, targetApp: String) async {
        guard !isBusy, !isRunning else { return }
        do {
            guard targetApp == "chatgpt" else {
                throw ConductorError.commandFailed("暂不支持该目标应用")
            }
            let node = try VLESSNode(uri: input)
            let url = URL(fileURLWithPath: configPath)
            let original = try Data(contentsOf: url)
            guard var config = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw ConductorError.commandFailed("配置必须是 JSON 对象")
            }
            var outbounds = config["outbounds"] as? [[String: Any]] ?? []
            let outbound: [String: Any] = [
                "type": "vless",
                "tag": "chatgpt-vless",
                "server": node.server,
                "server_port": node.port,
                "uuid": node.uuid,
                "flow": node.flow,
                "tls": [
                    "enabled": true,
                    "server_name": node.sni,
                    "utls": ["enabled": true, "fingerprint": node.fingerprint],
                    "reality": [
                        "enabled": true,
                        "public_key": node.publicKey,
                        "short_id": node.shortID
                    ]
                ]
            ]
            if let index = outbounds.firstIndex(where: { $0["tag"] as? String == "chatgpt-vless" }) {
                guard outbounds[index]["type"] as? String == "vless" else {
                    throw ConductorError.operationFailed("chatgpt-vless 标签已被其他类型出口占用，无法导入")
                }
                outbounds[index] = outbound
            } else {
                outbounds.insert(outbound, at: 0)
            }
            config["outbounds"] = outbounds

            var route = config["route"] as? [String: Any] ?? [:]
            var rules = route["rules"] as? [[String: Any]] ?? []
            let chatGPTDomains = [
                "chatgpt.com", "chat.openai.com", "openai.com",
                "auth.openai.com", "auth0.openai.com", "api.openai.com",
                "oaistatic.com", "oaiusercontent.com", "cdn.oaistatic.com"
            ]
            rules.removeAll { rule in
                guard rule["outbound"] as? String == "chatgpt-vless" else { return false }
                let keys = Set(rule.keys)
                let domains = Self.stringValues(rule["domain_suffix"])
                if !domains.isEmpty, keys.isSubset(of: ["domain_suffix", "action", "outbound"]) {
                    return Set(domains).isSubset(of: Set(chatGPTDomains))
                }
                let paths = Self.stringValues(rule["process_path"])
                if !paths.isEmpty, keys.isSubset(of: ["process_path", "action", "outbound"]) {
                    return paths.allSatisfy { $0.hasPrefix("/Applications/ChatGPT.app/") }
                }
                let names = Self.stringValues(rule["process_name"])
                if !names.isEmpty, keys.isSubset(of: ["process_name", "action", "outbound"]) {
                    let known = Set(["ChatGPT", "ChatGPT Helper", "ChatGPT Helper (GPU)", "ChatGPT Helper (Renderer)"])
                    return Set(names).isSubset(of: known)
                }
                return false
            }
            let appRules: [[String: Any]] = [
                [
                    "process_path": ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"],
                    "action": "route",
                    "outbound": "chatgpt-vless"
                ],
                [
                    "process_name": ["ChatGPT", "ChatGPT Helper", "ChatGPT Helper (GPU)", "ChatGPT Helper (Renderer)"],
                    "action": "route",
                    "outbound": "chatgpt-vless"
                ],
                [
                    "domain_suffix": chatGPTDomains,
                    "action": "route",
                    "outbound": "chatgpt-vless"
                ]
            ]
            let insertionIndex = rules.lastIndex(where: { $0["outbound"] as? String == "direct" }).map { $0 + 1 } ?? 0
            rules.insert(contentsOf: appRules, at: insertionIndex)
            route["rules"] = rules
            config["route"] = route
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.writePrivateTemporary(data, to: temporary)
            status = .validating
            let result = try await runProcess(arguments: ["check", "-c", temporary.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            guard try Data(contentsOf: url) == original else { throw ConductorError.commandFailed("配置已被外部修改，请重试") }
            let backup = url.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastError = nil
            status = .stopped
            appendLog("VLESS 节点已导入：\(node.server):\(node.port)。\n")
            operationMessage = "VLESS 节点已保存，下次启动代理时生效"
            reloadConfigurationSummary()
            reloadHistory()
        } catch { fail(error.localizedDescription) }
    }

    private func runCheck() async throws {
        let result = try await runProcess(arguments: ["check", "-c", configPath])
        appendLog(result.output)
        if result.status != 0 { throw ConductorError.commandFailed(result.output) }
    }

    private func requireSupportedRuntime() async throws {
        let result = try await runProcess(arguments: ["version"])
        let version = result.output.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "sing-box version ", with: "") ?? "未知"
        runtimeVersion = version
        guard result.status == 0, Self.isSupportedSingBoxVersion(version) else {
            runtimeHealth = .failed
            throw ConductorError.commandFailed("当前 sing-box 为 \(version)，低于 Conductor 1.0 要求的最低版本 \(Self.minimumSupportedRuntimeVersion)")
        }
        runtimeHealth = .healthy
    }

    private func launchProcess() async {
        let logURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/Conductor/sing-box.log")
        let pidURL = pidFileURL
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: logURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            let command = "mkdir -p \(shellQuote(logURL.deletingLastPathComponent().path)); "
                + "\(shellQuote(singBoxPath)) run -c \(shellQuote(configPath)) < /dev/null > \(shellQuote(logURL.path)) 2>&1 & "
                + "echo $! > \(shellQuote(pidURL.path))"
            let result = try await runAppleScript(command: command)
            guard result.status == 0,
                  let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
                  let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                fail(result.output.isEmpty ? "未能获得 sing-box 进程权限" : result.output)
                return
            }
            privilegedPID = pid
            status = .running
            lastError = nil
            monitorPrivilegedProcess(pid: pid, logURL: logURL)
        } catch {
            fail("无法请求管理员权限启动 sing-box：\(error.localizedDescription)")
        }
    }

    private func monitorPrivilegedProcess(pid: Int32, logURL: URL) {
        logMonitorTask?.cancel()
        lastRuntimeLog = ""
        clearedRuntimeLogPrefix = ""
        logMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let text = try? String(contentsOf: logURL, encoding: .utf8), let self {
                    let sanitized = Self.redactLogPasswords(text)
                    if sanitized != self.lastRuntimeLog {
                        self.lastRuntimeLog = sanitized
                        let result = Self.visibleRuntimeLog(sanitized, clearedPrefix: self.clearedRuntimeLogPrefix)
                        self.clearedRuntimeLogPrefix = result.prefix
                        self.logs = result.visible
                    }
                }
                if self?.isProcessRunning(pid) != true {
                    if self?.status == .stopping { self?.privilegedPID = nil; self?.status = .stopped }
                    else if self?.privilegedPID == pid { self?.privilegedPID = nil; self?.status = .failed }
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopPrivilegedProcess(pid: Int32) async {
        do {
            let result = try await runAppleScript(command: "kill -TERM \(pid)")
            guard result.status == 0 else {
                throw ConductorError.commandFailed(result.output.isEmpty ? "停止命令失败" : result.output)
            }
        } catch {
            fail("无法停止 sing-box：\(error.localizedDescription)")
        }
    }

    private func isProcessRunning(_ pid: Int32) -> Bool {
        Self.processExists(pid)
    }

    nonisolated static func livePID(in url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, processExists(pid) else { return nil }
        return pid
    }

    private static func previousPIDWarning(_ pid: Int32) -> String {
        "上次记录的进程 \(pid) 仍存在，无法确认是否属于 Conductor。请先核对该进程，再启动代理。"
    }

    nonisolated private static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func runAppleScript(command: String) async throws -> ProcessResult {
        let script = ["-e", "do shell script \(appleScriptQuote(command)) with administrator privileges"]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = script
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func runProcess(arguments: [String]) async throws -> ProcessResult {
        try await Self.runDetachedProcess(executable: singBoxPath, arguments: arguments)
    }

    private func runSystemProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await Self.runDetachedProcess(executable: executable, arguments: arguments)
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        logs += Self.redactLogPasswords(text)
        if logs.count > 50_000 { logs = String(logs.suffix(50_000)) }
    }

    nonisolated static func writePrivateTemporary(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    static func redactLogPasswords(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)password=[^\\r\\n]*", with: "password=[已隐藏]", options: .regularExpression)
    }

    static func visibleRuntimeLog(_ text: String, clearedPrefix: String) -> (visible: String, prefix: String) {
        let prefix = text.hasPrefix(clearedPrefix) ? clearedPrefix : ""
        return (String(text.dropFirst(prefix.count).suffix(50_000)), prefix)
    }

    static func logLines(_ text: String, filter: LogFilter, search: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.filter { line in
            let categoryMatch: Bool = switch filter {
            case .all: true
            case .vless: line.localizedCaseInsensitiveContains("vless") || line.localizedCaseInsensitiveContains("openai")
            case .localProxy: line.localizedCaseInsensitiveContains("socks") || line.localizedCaseInsensitiveContains("http")
            case .companyVPN: line.localizedCaseInsensitiveContains("utun") || line.localizedCaseInsensitiveContains("vpn")
            case .direct: line.localizedCaseInsensitiveContains("direct")
            case .errors: line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("fatal") || line.localizedCaseInsensitiveContains("warning")
            }
            return categoryMatch && (search.isEmpty || line.localizedCaseInsensitiveContains(search))
        }
    }

    private func fail(_ message: String) {
        operationMessage = nil
        lastError = message
        appendLog("ERROR \(message)\n")
        status = isRunning ? .running : .configurationError
    }

    private static func findSingBox() -> String {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/sing-box").path
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/sing-box").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
#if DEBUG
        if let development = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) { return development }
#endif
        return bundled
    }

    private static func runDetachedProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func maskHost(_ host: String) -> String {
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return host }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return host }
        return "\(parts[0]).***.***.\(parts[3])"
    }

    private func managedExcludedProcessPaths(for tag: String) -> [String] {
        let values = UserDefaults.standard.dictionary(forKey: proxyExclusionsDefaultsKey) as? [String: [String]]
        return values?[tag] ?? []
    }

    private func setManagedExcludedProcessPaths(_ paths: [String], for tag: String) {
        var values = UserDefaults.standard.dictionary(forKey: proxyExclusionsDefaultsKey) as? [String: [String]] ?? [:]
        if paths.isEmpty { values.removeValue(forKey: tag) }
        else { values[tag] = paths }
        UserDefaults.standard.set(values, forKey: proxyExclusionsDefaultsKey)
    }

    private func stringSet(forKey key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private func setMembership(_ included: Bool, tag: String, key: String) {
        var values = stringSet(forKey: key)
        if included { values.insert(tag) } else { values.remove(tag) }
        UserDefaults.standard.set(values.sorted(), forKey: key)
    }

    private static func isManagedUDP443RejectRule(_ rule: [String: Any]) -> Bool {
        Set(rule.keys) == Set(["network", "port", "action"]) &&
            rule["network"] as? String == "udp" && rule["port"] as? Int == 443 && rule["action"] as? String == "reject"
    }

    private static func removeManagedUDP443RejectRule(from rules: inout [[String: Any]]) {
        if let index = rules.lastIndex(where: isManagedUDP443RejectRule) {
            rules.remove(at: index)
        }
    }

    nonisolated private static func probeHTTPConnect(host: String, port: Int, username: String, password: String) -> Bool {
        guard let descriptor = connectSocket(host: host, port: port) else { return false }
        defer { Darwin.close(descriptor) }
        let authorization = username.isEmpty ? "" : "Proxy-Authorization: Basic \(Data("\(username):\(password)".utf8).base64EncodedString())\r\n"
        let request = "CONNECT www.apple.com:443 HTTP/1.1\r\nHost: www.apple.com:443\r\n\(authorization)Connection: close\r\n\r\n"
        guard sendAll(descriptor, bytes: Array(request.utf8)) else { return false }
        var response: [UInt8] = []
        while response.count < 1024 {
            var byte = [UInt8](repeating: 0, count: 1)
            guard receiveExact(descriptor, into: &byte) else { return false }
            response.append(byte[0])
            if byte[0] == 0x0A {
                let fields = String(decoding: response, as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
                return fields.count >= 2 && fields[0].hasPrefix("HTTP/") && fields[1] == "200"
            }
        }
        return false
    }

    nonisolated private static func probeSOCKS5(host: String, port: Int, command: UInt8, username: String, password: String) -> Bool {
        guard let descriptor = connectSocket(host: host, port: port) else { return false }
        defer { Darwin.close(descriptor) }
        let userBytes = Array(username.utf8), passwordBytes = Array(password.utf8)
        guard userBytes.count <= 255, passwordBytes.count <= 255 else { return false }
        let method: UInt8 = username.isEmpty ? 0x00 : 0x02
        guard sendAll(descriptor, bytes: [0x05, 0x01, method]) else { return false }
        var greeting = [UInt8](repeating: 0, count: 2)
        guard receiveExact(descriptor, into: &greeting), greeting == [0x05, method] else { return false }
        if method == 0x02 {
            guard !passwordBytes.isEmpty, sendAll(descriptor, bytes: [0x01, UInt8(userBytes.count)] + userBytes + [UInt8(passwordBytes.count)] + passwordBytes) else { return false }
            var auth = [UInt8](repeating: 0, count: 2)
            guard receiveExact(descriptor, into: &auth), auth == [0x01, 0x00] else { return false }
        }
        let request: [UInt8]
        if command == 0x03 {
            request = [0x05, command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        } else {
            let domain = Array("www.apple.com".utf8)
            request = [0x05, command, 0x00, 0x03, UInt8(domain.count)] + domain + [0x01, 0xBB]
        }
        guard sendAll(descriptor, bytes: request) else { return false }
        var response = [UInt8](repeating: 0, count: 4)
        guard receiveExact(descriptor, into: &response), response[0] == 0x05, response[1] == 0x00, response[2] == 0x00 else { return false }
        let addressLength: Int
        switch response[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03:
            var length = [UInt8](repeating: 0, count: 1)
            guard receiveExact(descriptor, into: &length), length[0] > 0 else { return false }
            addressLength = Int(length[0])
        default: return false
        }
        var addressAndPort = [UInt8](repeating: 0, count: addressLength + 2)
        return receiveExact(descriptor, into: &addressAndPort)
    }

    nonisolated private static func connectSocket(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else { return nil }
        defer { if let result { freeaddrinfo(result) } }
        var current = result
        while let address = current {
            let descriptor = Darwin.socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if descriptor >= 0 {
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var suppressSignal: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal, socklen_t(MemoryLayout<Int32>.size))
                let originalFlags = fcntl(descriptor, F_GETFL, 0)
                guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                    Darwin.close(descriptor)
                    current = address.pointee.ai_next
                    continue
                }
                let connection = Darwin.connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen)
                var connected = connection == 0
                if !connected && errno == EINPROGRESS {
                    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    if Darwin.poll(&pending, 1, 5_000) > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        connected = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
                    }
                }
                if connected && fcntl(descriptor, F_SETFL, originalFlags) == 0 { return descriptor }
                Darwin.close(descriptor)
            }
            current = address.pointee.ai_next
        }
        return nil
    }

    nonisolated private static func sendAll(_ descriptor: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }

    nonisolated private static func receiveExact(_ descriptor: Int32, into bytes: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            }
            if received <= 0 { return false }
            offset += received
        }
        return true
    }

    func executablePaths(inApplication applicationURL: URL) -> [String] {
        guard applicationURL.pathExtension.lowercased() == "app" else { return [] }
        let contentsURL = applicationURL.appendingPathComponent("Contents")
        guard let enumerator = FileManager.default.enumerator(
            at: contentsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.deletingLastPathComponent().lastPathComponent == "MacOS",
                  FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            paths.append(url.path)
        }
        return Array(Set(paths)).sorted()
    }

    static func isValidProxyEndpoint(_ value: String) -> Bool {
        parseEndpoint(value) != nil
    }

    private static func parseEndpoint(_ value: String) -> (host: String, port: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: "proxy://\(trimmed)"),
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              let port = components.port, (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static let defaultCompanyVPNs: [CompanyVPNObservation] = [
        CompanyVPNObservation(id: "openvpn", name: "OpenVPN", processPattern: "openvpn|OpenVPN Connect", state: .uncertain, interfaceName: nil, networks: ["10.247.53.0/24"], evidence: "尚未检查", checkedAt: nil),
        CompanyVPNObservation(id: "easyconnect", name: "EasyConnect", processPattern: "EasyConnect|EasyMonitor", state: .uncertain, interfaceName: nil, networks: ["10.248.0.0/14"], evidence: "尚未检查", checkedAt: nil),
        CompanyVPNObservation(id: "atrust", name: "aTrust", processPattern: "aTrust|Sangfor", state: .uncertain, interfaceName: nil, networks: ["20.20.20.0/24", "172.30.224.0/24"], evidence: "尚未检查", checkedAt: nil)
    ]
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private enum ConductorError: LocalizedError {
    case commandFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            output.isEmpty ? "sing-box 配置检查失败" : "sing-box 配置检查失败：\n\(output)"
        case .operationFailed(let message): message
        }
    }
}

private struct VLESSNode {
    let uuid: String
    let server: String
    let port: Int
    let flow: String
    let sni: String
    let fingerprint: String
    let publicKey: String
    let shortID: String

    init(uri: String) throws {
        guard let components = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "vless",
              let host = components.host,
              !host.isEmpty,
              let port = components.port, (1...65535).contains(port),
              let user = components.user,
              UUID(uuidString: user) != nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              let queryItems = components.queryItems else {
            throw ConductorError.commandFailed("VLESS 地址格式无效")
        }
        var values: [String: String] = [:]
        for item in queryItems {
            let key = item.name.lowercased()
            guard values[key] == nil else {
                throw ConductorError.commandFailed("VLESS 地址包含重复参数：\(key)")
            }
            guard let value = item.value else { throw ConductorError.operationFailed("VLESS 参数缺少值：\(key)") }
            values[key] = value
        }
        let supported = Set(["security", "flow", "sni", "fp", "pbk", "sid", "encryption", "type", "headertype"])
        if let unsupported = values.keys.sorted().first(where: { !supported.contains($0) }) {
            throw ConductorError.operationFailed("暂不支持 VLESS 参数：\(unsupported)")
        }
        if let type = values["type"], !["tcp", "raw"].contains(type.lowercased()) {
            throw ConductorError.operationFailed("当前只支持 TCP 传输")
        }
        if let encryption = values["encryption"], encryption.lowercased() != "none" {
            throw ConductorError.operationFailed("当前只支持 encryption=none")
        }
        if let header = values["headertype"], header.lowercased() != "none" {
            throw ConductorError.operationFailed("当前不支持 TCP 伪装头")
        }
        func required(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty else {
                throw ConductorError.commandFailed("VLESS 地址缺少参数：\(name)")
            }
            return value
        }
        guard values["security"]?.lowercased() == "reality" else {
            throw ConductorError.commandFailed("当前只支持 VLESS Reality 节点")
        }
        self.uuid = user
        self.server = host
        self.port = port
        self.flow = try required("flow")
        self.sni = try required("sni")
        self.fingerprint = try required("fp")
        self.publicKey = try required("pbk")
        self.shortID = try required("sid")
    }
}
