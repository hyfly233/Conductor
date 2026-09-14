import AppKit
import Combine
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

    private(set) var process: Process?
    private var outputPipe: Pipe?
    private var privilegedPID: Int32?
    private var logMonitorTask: Task<Void, Never>?
    private let proxyExclusionsDefaultsKey = "proxyExcludedProcessPaths"
    let configPath: String
    let singBoxPath: String

    init(configPath: String = "\(NSHomeDirectory())/sing-box/config.json", singBoxPath: String? = nil) {
        self.configPath = configPath
        self.singBoxPath = singBoxPath ?? Self.findSingBox()
        reloadConfigurationSummary()
        reloadHistory()
        companyVPNs = Self.defaultCompanyVPNs
    }

    var isRunning: Bool {
        if process?.isRunning == true { return true }
        if let privilegedPID { return isProcessRunning(privilegedPID) }
        return false
    }
    var isBusy: Bool {
        switch status {
        case .validating, .starting, .stopping: true
        default: false
        }
    }

    func toggle() async {
        if isRunning { stop() } else { await start() }
    }

    func start() async {
        guard !isBusy, !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: singBoxPath) else {
            fail("找不到 sing-box：\(singBoxPath)")
            return
        }
        status = .validating
        do {
            try await requireSupportedRuntime()
            try await runCheck()
            status = .starting
            launchProcess()
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
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        if let privilegedPID {
            status = .stopping
            stopPrivilegedProcess(pid: privilegedPID)
            return
        }
        guard let process, process.isRunning else {
            self.process = nil
            status = .stopped
            return
        }
        status = .stopping
        process.terminate()
    }

    func refreshStatus() {
        if process?.isRunning == true || (privilegedPID.map(isProcessRunning) == true) { status = .running }
        else if status == .running { status = .stopped }
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
        logs = ""
    }

    func checkRuntime() async {
        runtimeHealth = .checking
        do {
            let result = try await runProcess(arguments: ["version"])
            let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? "未知版本"
            runtimeVersion = firstLine.replacingOccurrences(of: "sing-box version ", with: "")
            runtimeHealth = result.status == 0 && runtimeVersion == "1.14.0" ? .healthy : .warning
            if runtimeHealth == .warning {
                lastError = "当前 sing-box 为 \(runtimeVersion)，Conductor 1.0 固定支持 1.14.0"
            } else {
                lastError = nil
            }
        } catch {
            runtimeVersion = "不可用"
            runtimeHealth = .failed
            lastError = error.localizedDescription
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
            var detectedInterface: String?
            for network in definition.networks {
                let target = network.split(separator: "/").first.map(String.init) ?? network
                if let route = try? await runSystemProcess(executable: "/sbin/route", arguments: ["-n", "get", target]), route.status == 0 {
                    evidence.append(route.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let line = route.output.split(separator: "\n").first(where: { $0.contains("interface:") }) {
                        detectedInterface = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            let processFound = processResult?.status == 0
            item.interfaceName = detectedInterface
            item.state = detectedInterface != nil ? .connected : (processFound ? .uncertain : .disconnected)
            item.evidence = evidence.isEmpty ? (processResult?.output ?? "未发现客户端进程或路由证据") : evidence.joined(separator: "\n\n")
            item.checkedAt = Date()
            observations.append(item)
        }
        companyVPNs = observations
    }

    func reloadConfigurationSummary() {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            proxyConfigurations = []
            return
        }
        let route = config["route"] as? [String: Any] ?? [:]
        let rules = route["rules"] as? [[String: Any]] ?? []
        let defaultOutbound = route["final"] as? String
        proxyConfigurations = (config["outbounds"] as? [[String: Any]] ?? []).compactMap { outbound in
            guard let type = outbound["type"] as? String,
                  ["vless", "socks", "http"].contains(type),
                  let tag = outbound["tag"] as? String else { return nil }
            let host = outbound["server"] as? String ?? "未配置"
            let port = outbound["server_port"] as? Int
            let endpoint = port.map { "\(Self.maskHost(host)):\($0)" } ?? Self.maskHost(host)
            var bindings: [String] = []
            if defaultOutbound == tag { bindings.append("剩余流量") }
            for rule in rules where rule["outbound"] as? String == tag {
                if rule["process_name"] != nil || rule["process_path"] != nil { bindings.append("应用") }
                if let domains = rule["domain_suffix"] as? [String], !domains.isEmpty {
                    bindings.append(domains.prefix(2).joined(separator: "、") + (domains.count > 2 ? " 等域名" : ""))
                }
                if rule["ip_cidr"] != nil { bindings.append("IP/CIDR") }
            }
            return ProxyConfiguration(
                id: tag,
                type: type.uppercased(),
                name: tag == "chatgpt-vless" ? "VPS" : tag,
                endpoint: endpoint,
                bindingSummary: bindings.isEmpty ? "未绑定流量" : Array(Set(bindings)).joined(separator: " · ")
            )
        }
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
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
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
            appendLog("已删除出口 \(id) 及其流量绑定，原配置已备份。\n")
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
            return ConfigurationHistoryItem(id: url.path, url: url, createdAt: date, reason: "配置变更备份")
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restoreHistory(_ item: ConfigurationHistoryItem) async {
        guard !isRunning, !isBusy else { return }
        status = .validating
        do {
            let result = try await runProcess(arguments: ["check", "-c", item.url.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            let current = URL(fileURLWithPath: configPath)
            if FileManager.default.fileExists(atPath: current.path) {
                let backup = current.appendingPathExtension("backup-restore-" + UUID().uuidString)
                try FileManager.default.copyItem(at: current, to: backup)
            }
            let data = try Data(contentsOf: item.url)
            try data.write(to: current, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            reloadConfigurationSummary()
            reloadHistory()
            status = .stopped
            lastError = nil
            appendLog("历史配置已恢复，并已备份恢复前配置。\n")
        } catch { fail(error.localizedDescription) }
    }

    func saveProxy(
        tag: String,
        kind: String,
        endpoint: String,
        domains: String,
        useAsDefault: Bool,
        excludedProcessPaths: [String]
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
            guard var config = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw ConductorError.commandFailed("配置必须是 JSON 对象")
            }
            var outbounds = config["outbounds"] as? [[String: Any]] ?? []
            let newOutbound: [String: Any] = ["type": kind, "tag": tag, "server": parsedEndpoint.host, "server_port": parsedEndpoint.port]
            if let existingIndex = outbounds.firstIndex(where: { $0["tag"] as? String == tag }) {
                outbounds[existingIndex] = newOutbound
            } else {
                outbounds.append(newOutbound)
            }
            config["outbounds"] = outbounds
            var route = config["route"] as? [String: Any] ?? [:]
            var rules = route["rules"] as? [[String: Any]] ?? []
            rules.removeAll { $0["outbound"] as? String == tag }
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
            } else {
                let suffixes = domains.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                guard !suffixes.isEmpty else { throw ConductorError.commandFailed("请填写至少一个域名后缀") }
                // Preserve process, company network and DNS rules before the default outbound.
                let index = rules.firstIndex { $0["domain_suffix"] != nil } ?? rules.endIndex
                rules.insert(["domain_suffix": suffixes, "action": "route", "outbound": tag], at: index)
            }
            route["rules"] = rules
            config["route"] = route
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let result = try await runProcess(arguments: ["check", "-c", temporary.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            guard try Data(contentsOf: url) == original else { throw ConductorError.commandFailed("配置已被外部修改，请重试") }
            let backup = url.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            setManagedExcludedProcessPaths(paths, for: tag)
            let exclusionText = paths.isEmpty ? "" : "，已排除 \(paths.count) 个 VPN 应用进程以避免代理回环"
            appendLog("已保存出口 \(tag)\(useAsDefault ? "，剩余流量将使用该出口" : "")\(exclusionText)，原配置已备份。端口实际连通性尚未验证。\n")
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
                if rule["outbound"] as? String == "chatgpt-vless" { return true }
                if let domains = rule["domain_suffix"] as? [String],
                   domains.contains(where: { chatGPTDomains.contains($0) }) { return true }
                if let paths = rule["process_path"] as? [String],
                   paths.contains(where: { $0.contains("/Applications/ChatGPT.app/") }) { return true }
                if let names = rule["process_name"] as? [String],
                   names.contains(where: { $0.localizedCaseInsensitiveContains("chatgpt") }) { return true }
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
            rules.insert(contentsOf: appRules, at: 0)
            route["rules"] = rules
            config["route"] = route
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary)
            let result = try await runProcess(arguments: ["check", "-c", temporary.path])
            guard result.status == 0 else { throw ConductorError.commandFailed(result.output) }
            let backup = url.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backup)
            try data.write(to: url, options: .atomic)
            lastError = nil
            status = .stopped
            appendLog("VLESS 节点已导入：\(node.server):\(node.port)。\n")
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
        guard result.status == 0, version == "1.14.0" else {
            runtimeHealth = .failed
            throw ConductorError.commandFailed("当前 sing-box 为 \(version)，Conductor 1.0 仅支持 1.14.0")
        }
        runtimeHealth = .healthy
    }

    private func launchProcess() {
        let logURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/Conductor/sing-box.log")
        let pidURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/Conductor/sing-box.pid")
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: logURL)
            let command = "mkdir -p \(shellQuote(logURL.deletingLastPathComponent().path)); "
                + "\(shellQuote(singBoxPath)) run -c \(shellQuote(configPath)) < /dev/null > \(shellQuote(logURL.path)) 2>&1 & "
                + "echo $! > \(shellQuote(pidURL.path))"
            let result = try runAppleScript(command: command)
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
        logMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let text = try? String(contentsOf: logURL, encoding: .utf8), text != self?.logs {
                    self?.logs = String(text.suffix(50_000))
                }
                if self?.isProcessRunning(pid) != true {
                    if self?.status == .stopping { self?.status = .stopped }
                    else if self?.privilegedPID == pid { self?.privilegedPID = nil; self?.status = .failed }
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopPrivilegedProcess(pid: Int32) {
        do {
            _ = try runAppleScript(command: "kill -TERM \(pid)")
            privilegedPID = nil
            logMonitorTask?.cancel()
            status = .stopped
        } catch {
            fail("无法停止 sing-box：\(error.localizedDescription)")
        }
    }

    private func isProcessRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func runAppleScript(command: String) throws -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptQuote(command)) with administrator privileges"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func runProcess(arguments: [String]) async throws -> ProcessResult {
        let executable = singBoxPath
        return try await withCheckedThrowingContinuation { continuation in
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
            } catch {
                continuation.resume(throwing: error)
            }
          }
        }
    }

    private func runSystemProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await Self.runDetachedProcess(executable: executable, arguments: arguments)
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        logs += text
        if logs.count > 50_000 { logs = String(logs.suffix(50_000)) }
    }

    private func fail(_ message: String) {
        lastError = message
        appendLog("\(message)\n")
        status = .configurationError
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
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func maskHost(_ host: String) -> String {
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

    private static func parseEndpoint(_ value: String) -> (host: String, port: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: "proxy://\(trimmed)"),
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

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            output.isEmpty ? "sing-box 配置检查失败" : "sing-box 配置检查失败：\n\(output)"
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
              let port = components.port,
              let user = components.user,
              let queryItems = components.queryItems else {
            throw ConductorError.commandFailed("VLESS 地址格式无效")
        }
        let values = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name.lowercased(), $0) }
        })
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
