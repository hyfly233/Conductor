import Foundation

@main
struct OperationChecks {
    @MainActor static func main() async throws {
        let redactedLog = ConductorController.redactLogPasswords("socks5: authentication failed, username=user, password=secret value\nnext line")
        precondition(redactedLog == "socks5: authentication failed, username=user, password=[已隐藏]\nnext line")
        precondition(!redactedLog.contains("secret"))
        let clearedLog = ConductorController.visibleRuntimeLog("old\nnew\n", clearedPrefix: "old\n")
        precondition(clearedLog.visible == "new\n" && clearedLog.prefix == "old\n")
        let rotated = ConductorController.visibleRuntimeLog("fresh\n", clearedPrefix: "old\n")
        precondition(rotated.visible == "fresh\n" && rotated.prefix.isEmpty)
        let sampleLog = "23:56:39 INFO  inbound/tun started\n23:56:40 INFO  outbound/chatgpt-vless selected\nproxy: socks5 connect failed\n23:56:45 ERROR vpn-proxy-01 unavailable\n"
        precondition(ConductorController.logLines(sampleLog, filter: .all, search: "").count == 4)
        precondition(ConductorController.logLines(sampleLog, filter: .vless, search: "") == ["23:56:40 INFO  outbound/chatgpt-vless selected"])
        precondition(ConductorController.logLines(sampleLog, filter: .localProxy, search: "") == ["proxy: socks5 connect failed"])
        precondition(ConductorController.logLines(sampleLog, filter: .errors, search: "") == ["23:56:45 ERROR vpn-proxy-01 unavailable"])
        precondition(ConductorController.logLines(sampleLog, filter: .all, search: "OUTBOUND").count == 1)
        precondition(ConductorController.logLines(sampleLog, filter: .errors, search: "chatgpt").isEmpty)
        precondition(ConductorController.companyVPNState(processStatus: 0, hasTunnelRoute: false) == .uncertain)
        precondition(ConductorController.companyVPNState(processStatus: 0, hasTunnelRoute: true) == .uncertain)
        precondition(ConductorController.companyVPNState(processStatus: 1, hasTunnelRoute: false) == .disconnected)
        precondition(ConductorController.companyVPNState(processStatus: 1, hasTunnelRoute: true) == .uncertain)
        precondition(ConductorController.companyVPNState(processStatus: nil, hasTunnelRoute: false) == .failed)
        precondition(ConductorController.companyVPNState(processStatus: 1, hasTunnelRoute: false, routesChecked: false) == .uncertain)
        for cidr in ["10.0.0.0/8", "192.0.2.1/32", "fd00::/8", "::1/128"] { precondition(ConductorController.isValidCIDR(cidr)) }
        for cidr in ["10.0.0.1", "10.0.0.0/33", "fd00::/129", "invalid/24", "0.0.0.0/-1"] { precondition(!ConductorController.isValidCIDR(cidr)) }
        precondition(ConductorController.normalizedIPOrCIDR("192.0.2.1") == "192.0.2.1/32")
        precondition(ConductorController.normalizedIPOrCIDR("2001:db8::1") == "2001:db8::1/128")
        precondition(ConductorController.normalizedIPOrCIDR("192.0.2.1/33") == nil)
        precondition(ConductorController.cidr("10.247.53.0/24", isCoveredBy: "10.0.0.0/8"))
        precondition(!ConductorController.cidr("10.0.0.0/8", isCoveredBy: "10.247.53.0/24"))
        precondition(ConductorController.cidr("10.128.0.0/9", isCoveredBy: "10.128.0.0/9"))
        precondition(!ConductorController.cidr("10.0.0.0/9", isCoveredBy: "10.128.0.0/9"))
        precondition(ConductorController.cidr("fd12:3456::/32", isCoveredBy: "fd00::/8"))
        precondition(!ConductorController.cidr("fd12::/16", isCoveredBy: "0.0.0.0/0"))
        precondition(!ConductorController.cidr("invalid/8", isCoveredBy: "0.0.0.0/0"))
        for endpoint in ["127.0.0.1:7890", "localhost:1080", "[::1]:7890", "proxy.example.com:65535"] {
            precondition(ConductorController.isValidProxyEndpoint(endpoint), endpoint)
        }
        for endpoint in ["", "localhost", "localhost:0", "localhost:65536", "localhost:7890/path", "user@localhost:7890", "localhost:7890?q=1"] {
            precondition(!ConductorController.isValidProxyEndpoint(endpoint), endpoint)
        }
        for http in [false, true] {
            for socks in [false, true] {
                for udp in [false, true] {
                    let result = MixedProxyProbeResult(httpAvailable: http, socksTCPAvailable: socks, socksUDPAvailable: udp)
                    precondition(result.selectedKind == (socks ? "socks" : (http ? "http" : nil)))
                    precondition(result.supportsUDP == (socks && udp))
                }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        let privateURL = directory.appendingPathComponent("private-config.json")
        try ConductorController.writePrivateTemporary(Data("fixture-secret".utf8), to: privateURL)
        let privatePermissions = try FileManager.default.attributesOfItem(atPath: privateURL.path)[.posixPermissions] as? NSNumber
        precondition(privatePermissions?.intValue == 0o600)
        do {
            try ConductorController.writePrivateTemporary(Data("replacement".utf8), to: privateURL)
            fatalError("Private temporary file must not overwrite an existing path")
        } catch {}
        let privateContents = try Data(contentsOf: privateURL)
        precondition(privateContents == Data("fixture-secret".utf8))
        let pidURL = directory.appendingPathComponent("test.pid")
        try String(getpid()).write(to: pidURL, atomically: true, encoding: .utf8)
        precondition(ConductorController.livePID(in: pidURL) == getpid())
        let guardedStart = ConductorController(configPath: configURL.path, singBoxPath: "/nonexistent", pidFileURL: pidURL)
        precondition(guardedStart.status == .failed && guardedStart.lastError?.contains("上次记录的进程") == true)
        await guardedStart.checkRuntime()
        precondition(guardedStart.status == .failed && guardedStart.lastError?.contains("上次记录的进程") == true)
        precondition(guardedStart.previousPIDNotice?.contains("上次记录的进程") == true)
        precondition(guardedStart.displayStatusTitle == "上次进程未确认")
        await guardedStart.start()
        precondition(guardedStart.status == .failed)
        precondition(guardedStart.lastError?.contains("上次记录的进程") == true)
        precondition(!guardedStart.isRunning)
        try "0".write(to: pidURL, atomically: true, encoding: .utf8)
        precondition(ConductorController.livePID(in: pidURL) == nil)
        try "not-a-pid".write(to: pidURL, atomically: true, encoding: .utf8)
        precondition(ConductorController.livePID(in: pidURL) == nil)
        let fixture: [String: Any] = [
            "outbounds": [["tag": "example", "type": "socks", "server": "::1", "server_port": 7890]],
            "dns": ["servers": [["type": "udp", "tag": "fixture-dns", "server": "1.1.1.1", "detour": "example"]]],
            "route": ["final": "example", "rules": [["outbound": "example", "domain_suffix": ["example.com"]]]]
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: configURL)
        let controller = ConductorController(configPath: configURL.path, singBoxPath: "/nonexistent")
        let values = controller.proxyEditorValues(tag: "example")
        precondition(values?.endpoint == "[::1]:7890")
        precondition(controller.proxyConfigurations.first?.endpoint == "[::1]:7890")
        precondition(values?.domains == "example.com")
        precondition(values?.isDefault == true)
        precondition(controller.proxyEditorValues(tag: "missing") == nil)
        precondition(controller.routingSummary == "剩余流量 → example")
        precondition(controller.dnsUsesOutbound(tag: "example"))
        precondition(!controller.dnsUsesOutbound(tag: "missing"))
        if let listener = ProcessInfo.processInfo.environment["CONDUCTOR_CHECK_LISTENER"] {
            let names = await controller.localListenerNames(endpoint: listener)
            guard let names else { fatalError("Could not inspect listener: \(listener)") }
            print("Listener check passed: \(names.joined(separator: ", "))")
        }
        if let endpoint = ProcessInfo.processInfo.environment["CONDUCTOR_CHECK_MIXED"] {
            let failedProbe = await controller.probeMixedProxy(endpoint: "127.0.0.1:1")
            precondition(failedProbe.selectedKind == nil)
            precondition(controller.lastError == nil)
            precondition(controller.status == .stopped)
            let probe = await controller.probeMixedProxy(endpoint: endpoint)
            precondition(controller.lastError == nil && controller.status == .stopped)
            print("Mixed probe: HTTP=\(probe.httpAvailable), SOCKS5=\(probe.socksTCPAvailable), UDP associate=\(probe.socksUDPAvailable), selected=\(probe.selectedKind ?? "none")")
        }
        if let endpoint = ProcessInfo.processInfo.environment["CONDUCTOR_CHECK_AUTH_PROXY"] {
            let good = await controller.probeMixedProxy(endpoint: endpoint, username: "test", password: "secret")
            precondition(good.httpAvailable && good.socksTCPAvailable && good.socksUDPAvailable)
            let bad = await controller.probeMixedProxy(endpoint: endpoint, username: "test", password: "wrong")
            precondition(bad.selectedKind == nil)
            precondition(controller.lastError == nil && controller.status == .stopped)
            print("Authenticated mixed proxy checks passed")
        }
        if let endpoint = ProcessInfo.processInfo.environment["CONDUCTOR_CHECK_TRUNCATED_PROXY"] {
            let result = await controller.probeMixedProxy(endpoint: endpoint, username: "test", password: "secret")
            precondition(!result.socksTCPAvailable && !result.socksUDPAvailable)
            print("Truncated SOCKS5 response rejected")
        }
        precondition(controller.nextProxyTag == "vpn-proxy-01")
        var occupied = fixture
        occupied["outbounds"] = [
            ["type": "http", "tag": "vpn-proxy-01", "server": "localhost", "server_port": 7890],
            ["type": "direct", "tag": "vpn-proxy-02"]
        ]
        try JSONSerialization.data(withJSONObject: occupied).write(to: configURL)
        controller.reloadConfigurationSummary()
        precondition(controller.nextProxyTag == "vpn-proxy-03")
        precondition(controller.existingOutboundType(tag: "vpn-proxy-01") == "http")
        precondition(controller.existingOutboundType(tag: "vpn-proxy-02") == "direct")
        precondition(controller.existingOutboundType(tag: "vpn-proxy-03") == nil)
        precondition(controller.proxyConfigurations.first?.endpoint == "localhost:7890")
        let occupiedData = try Data(contentsOf: configURL)
        let conflict = ConductorController(configPath: configURL.path, singBoxPath: "/usr/bin/true")
        await conflict.saveProxy(tag: "vpn-proxy-02", kind: "http", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: false, wasAutoDetected: false)
        precondition(conflict.lastError != nil)
        let afterConflict = try Data(contentsOf: configURL)
        precondition(afterConflict == occupiedData)
        precondition(conflict.configurationHistory.isEmpty)
        try JSONSerialization.data(withJSONObject: fixture).write(to: configURL)
        // The command stub isolates mutation semantics; it does not validate sing-box syntax.
        let mutation = ConductorController(configPath: configURL.path, singBoxPath: "/usr/bin/true")
        var advanced = fixture
        advanced["outbounds"] = [["tag": "example", "type": "socks", "server": "::1", "server_port": 7890, "username": "test", "password": "fixture-only"]]
        advanced["route"] = ["final": "example", "rules": [
            ["outbound": "example", "domain_suffix": ["example.com"]],
            ["outbound": "example", "process_name": ["ExampleHelper"]],
            ["outbound": "example", "domain_suffix": ["restricted.example"], "process_name": ["RestrictedApp"]],
            ["outbound": "example", "ip_cidr": ["203.0.113.0/24"]]
        ]]
        try JSONSerialization.data(withJSONObject: advanced).write(to: configURL)
        precondition(mutation.proxyEditorValues(tag: "example")?.domains == "example.com")
        precondition(mutation.proxyEditorValues(tag: "example")?.username == "test")
        precondition(mutation.proxyEditorValues(tag: "example")?.password == "fixture-only")
        let beforeDuplicate = try Data(contentsOf: configURL)
        let staleEditor = ConductorController(configPath: configURL.path, singBoxPath: "/usr/bin/true")
        await staleEditor.saveProxy(tag: "example", kind: "socks", endpoint: "127.0.0.1:1080", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, credentials: ("", ""), expectedConfig: Data("old configuration".utf8))
        precondition(staleEditor.lastError != nil)
        let afterStaleEdit = try Data(contentsOf: configURL)
        precondition(afterStaleEdit == beforeDuplicate)
        let duplicate = ConductorController(configPath: configURL.path, singBoxPath: "/usr/bin/true")
        await duplicate.saveProxy(tag: "example", kind: "socks", endpoint: "127.0.0.1:1080", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, credentials: ("", ""), requireNew: true)
        precondition(duplicate.lastError != nil)
        let afterDuplicate = try Data(contentsOf: configURL)
        precondition(afterDuplicate == beforeDuplicate)
        await mutation.saveProxy(tag: "example", kind: "socks", endpoint: "127.0.0.1:1080", domains: "new.example", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false)
        precondition(mutation.lastError == nil)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        let outbound = (saved["outbounds"] as! [[String: Any]])[0]
        precondition(outbound["username"] as? String == "test")
        precondition(outbound["password"] as? String == "fixture-only")
        precondition(outbound["server_port"] as? Int == 1080)
        let route = saved["route"] as! [String: Any]
        precondition(route["final"] as? String == "direct")
        let rules = route["rules"] as! [[String: Any]]
        precondition(rules.contains { $0["process_name"] as? [String] == ["ExampleHelper"] })
        precondition(rules.contains { $0["ip_cidr"] as? [String] == ["203.0.113.0/24"] })
        precondition(rules.contains { $0["domain_suffix"] as? [String] == ["new.example"] })
        precondition(rules.contains {
            $0["domain_suffix"] as? [String] == ["restricted.example"] && $0["process_name"] as? [String] == ["RestrictedApp"]
        })
        precondition(!rules.contains {
            $0["domain_suffix"] as? [String] == ["restricted.example"] && $0["process_name"] == nil
        })
        await mutation.deleteProxyConfiguration(id: "example")
        precondition(mutation.lastError == nil)
        precondition(mutation.proxyConfigurations.isEmpty)
        let deleted = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        let remainingDNS = ((deleted["dns"] as! [String: Any])["servers"] as! [[String: Any]])[0]
        precondition(remainingDNS["detour"] == nil)
        let remainingRules = (deleted["route"] as! [String: Any])["rules"] as! [[String: Any]]
        precondition(!remainingRules.contains { $0["outbound"] as? String == "example" })
        precondition(mutation.configurationHistory.count == 2)
        let beforeFailure = try Data(contentsOf: configURL)
        let rejecting = ConductorController(configPath: configURL.path, singBoxPath: "/usr/bin/false")
        await rejecting.saveProxy(tag: "rejected-example", kind: "http", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: false, wasAutoDetected: false)
        precondition(rejecting.lastError != nil)
        precondition(rejecting.operationMessage == nil)
        let afterFailure = try Data(contentsOf: configURL)
        precondition(beforeFailure == afterFailure)
        precondition(rejecting.configurationHistory.count == 2)
        await mutation.saveProxy(tag: "auth-example", kind: "socks", endpoint: "127.0.0.1:1080", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, credentials: ("user", "secret"))
        precondition(mutation.lastError == nil)
        precondition(mutation.proxyEditorValues(tag: "auth-example")?.password == "secret")
        await mutation.saveProxy(tag: "auth-example", kind: "socks", endpoint: "127.0.0.1:1080", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, credentials: ("", ""))
        precondition(mutation.lastError == nil)
        let cleared = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        let clearedOutbound = (cleared["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "auth-example" }!
        precondition(clearedOutbound["username"] == nil && clearedOutbound["password"] == nil)
        try Data("invalid-json".utf8).write(to: configURL)
        mutation.reloadConfigurationSummary()
        precondition(mutation.configurationReadError != nil)
        precondition(mutation.routingSummary == "配置不可读取")
        try beforeFailure.write(to: configURL)
        mutation.reloadConfigurationSummary()
        precondition(mutation.configurationReadError == nil)
        print("Operation checks passed: endpoint validation, protocol selection, editor prefill, routing summary")
        print("Mutation checks passed: credentials, advanced bindings, default reset, deletion, backups (stub validator)")
        print("Failure checks passed: original configuration preserved, no success message or extra backup")
        if let runtime = ProcessInfo.processInfo.environment["CONDUCTOR_CHECK_RUNTIME"] {
            let tunURL = directory.appendingPathComponent("tun-config.json")
            let tunFixture: [String: Any] = [
                "inbounds": [["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "route_exclude_address": ["192.0.2.0/24"]]],
                "outbounds": [["type": "direct", "tag": "direct"]], "route": ["final": "direct"]
            ]
            try JSONSerialization.data(withJSONObject: tunFixture).write(to: tunURL)
            let tun = ConductorController(configPath: tunURL.path, singBoxPath: runtime)
            let initialTun = tun.tunExclusions()!
            precondition(initialTun.values == ["192.0.2.0/24"])
            await tun.saveTUNExclusions(["192.0.2.0/24", "10.0.0.0/8"], expectedConfig: initialTun.snapshot)
            precondition(tun.lastError == nil, tun.lastError ?? "")
            let updatedTun = tun.tunExclusions()!
            precondition(updatedTun.values == ["192.0.2.0/24", "10.0.0.0/8"] && tun.configurationHistory.count == 1)
            await tun.saveTUNExclusions(["invalid/8"], expectedConfig: updatedTun.snapshot)
            precondition(tun.lastError != nil && tun.status == .stopped && tun.tunExclusions()!.snapshot == updatedTun.snapshot)
            let inputError = tun.lastError
            tun.clearError(ifMatching: "different error")
            precondition(tun.lastError == inputError)
            tun.clearError(ifMatching: inputError)
            precondition(tun.lastError == nil)
            await tun.saveTUNExclusions([], expectedConfig: initialTun.snapshot)
            precondition(tun.lastError == "配置已变化，请关闭窗口并重新编辑" && tun.status == .stopped && tun.tunExclusions()!.snapshot == updatedTun.snapshot)
            await tun.saveTUNExclusions(["192.0.2.0/24"], expectedConfig: updatedTun.snapshot)
            precondition(tun.lastError == nil && tun.tunExclusions()!.values == ["192.0.2.0/24"])
            var scalarFixture = tunFixture
            scalarFixture["inbounds"] = [["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "route_exclude_address": "192.0.2.0/24"]]
            try JSONSerialization.data(withJSONObject: scalarFixture).write(to: tunURL)
            await tun.validateConfiguration()
            precondition(tun.lastError == nil, tun.lastError ?? "")
            let scalarTun = tun.tunExclusions()!
            precondition(scalarTun.values == ["192.0.2.0/24"])
            await tun.saveTUNExclusions(["192.0.2.0/24", "10.0.0.0/8"], expectedConfig: scalarTun.snapshot)
            precondition(tun.lastError == nil && tun.tunExclusions()!.values == ["192.0.2.0/24", "10.0.0.0/8"])
            let rejectedTun = ConductorController(configPath: tunURL.path, singBoxPath: "/usr/bin/false")
            let beforeRejectedTun = rejectedTun.tunExclusions()!.snapshot
            let backupsBeforeRejectedTun = rejectedTun.configurationHistory.count
            await rejectedTun.saveTUNExclusions(["10.1.0.0/16"], expectedConfig: beforeRejectedTun)
            precondition(rejectedTun.lastError != nil && rejectedTun.status == .stopped)
            precondition(rejectedTun.tunExclusions()!.snapshot == beforeRejectedTun)
            precondition(rejectedTun.configurationHistory.count == backupsBeforeRejectedTun)
            print("Real TUN exclusion checks passed: preserve, edit, invalid input, stale snapshot")
            let ipURL = directory.appendingPathComponent("ip-config.json")
            let ipFixture: [String: Any] = ["outbounds": [["type": "direct", "tag": "direct"], ["type": "socks", "tag": "ip-test", "server": "127.0.0.1", "server_port": 7890]],
                "route": ["final": "direct", "rules": [
                    ["ip_cidr": ["10.0.0.0/8"], "outbound": "direct"],
                    ["domain_suffix": "old.example", "outbound": "ip-test"],
                    ["ip_cidr": ["203.0.113.0/24"], "process_name": ["Example"], "outbound": "ip-test"]
                ]]]
            try JSONSerialization.data(withJSONObject: ipFixture).write(to: ipURL)
            let ipController = ConductorController(configPath: ipURL.path, singBoxPath: runtime)
            await ipController.validateConfiguration()
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            precondition(ipController.proxyEditorValues(tag: "ip-test")?.domains == "old.example")
            precondition(ipController.proxyConfigurations.first { $0.id == "ip-test" }?.bindingSummary.contains("old.example") == true)
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, destinationCIDRs: ["192.0.2.1", "2001:db8::/32"])
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            let ipSaved = try JSONSerialization.jsonObject(with: Data(contentsOf: ipURL)) as! [String: Any]
            let ipRules = (ipSaved["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(ipRules.first?["outbound"] as? String == "direct")
            precondition(ipRules.contains { $0["domain_suffix"] as? String == "old.example" })
            precondition(ipRules.contains { $0["process_name"] as? [String] == ["Example"] && $0["ip_cidr"] as? [String] == ["203.0.113.0/24"] })
            precondition(ipController.proxyEditorValues(tag: "ip-test")?.cidrs == "192.0.2.1/32, 2001:db8::/32")
            print("Real IP binding checks passed: normalization, precedence, advanced-rule preservation")
            let targetPath = "/Applications/Example.app/Contents/MacOS/Example"
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, destinationAppPaths: [targetPath])
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            let appSaved = try JSONSerialization.jsonObject(with: Data(contentsOf: ipURL)) as! [String: Any]
            let appRoute = appSaved["route"] as! [String: Any]
            let appRules = appRoute["rules"] as! [[String: Any]]
            precondition(appRoute["find_process"] as? Bool == true)
            precondition(appRules.first?["outbound"] as? String == "direct")
            precondition(appRules.contains { $0["process_path"] as? [String] == [targetPath] && $0["outbound"] as? String == "ip-test" })
            precondition(appRules.contains { $0["domain_suffix"] as? String == "old.example" })
            precondition(appRules.contains { $0["ip_cidr"] as? [String] == ["192.0.2.1/32", "2001:db8::/32"] })
            precondition(appRules.contains { $0["process_name"] as? [String] == ["Example"] && $0["ip_cidr"] as? [String] == ["203.0.113.0/24"] })
            precondition(ipController.proxyEditorValues(tag: "ip-test")?.applications == [targetPath])
            let beforeConflictApp = try Data(contentsOf: ipURL)
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: false, excludedProcessPaths: [targetPath], supportsUDP: true, wasAutoDetected: false, destinationAppPaths: [targetPath])
            precondition(ipController.lastError != nil)
            let afterConflictApp = try Data(contentsOf: ipURL)
            precondition(beforeConflictApp == afterConflictApp)
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false)
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            let defaultSaved = try JSONSerialization.jsonObject(with: Data(contentsOf: ipURL)) as! [String: Any]
            let defaultRules = (defaultSaved["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(defaultRules.contains { $0["domain_suffix"] as? String == "old.example" })
            precondition(defaultRules.contains { $0["process_path"] as? [String] == [targetPath] })
            precondition(defaultRules.contains { $0["ip_cidr"] as? [String] == ["192.0.2.1/32", "2001:db8::/32"] })
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false)
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            let clearedDomain = try JSONSerialization.jsonObject(with: Data(contentsOf: ipURL)) as! [String: Any]
            let clearedDomainRules = (clearedDomain["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(!clearedDomainRules.contains { $0["domain_suffix"] as? String == "old.example" })
            precondition(clearedDomainRules.contains { $0["process_path"] as? [String] == [targetPath] })
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, destinationAppPaths: [])
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            await ipController.saveProxy(tag: "ip-test", kind: "socks", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, destinationCIDRs: [])
            precondition(ipController.lastError == nil, ipController.lastError ?? "")
            let clearedBindings = try JSONSerialization.jsonObject(with: Data(contentsOf: ipURL)) as! [String: Any]
            let clearedRules = (clearedBindings["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(!clearedRules.contains { $0["process_path"] as? [String] == [targetPath] })
            precondition(!clearedRules.contains { $0["ip_cidr"] as? [String] == ["192.0.2.1/32", "2001:db8::/32"] })
            precondition(clearedRules.contains { $0["process_name"] as? [String] == ["Example"] && $0["ip_cidr"] as? [String] == ["203.0.113.0/24"] })
            print("Real application binding checks passed: path rule, priority, preservation, loop conflict")
            let realFixture: [String: Any] = [
                "outbounds": [["type": "direct", "tag": "direct"]],
                "route": ["final": "direct", "rules": [
                    ["ip_cidr": ["10.247.53.0/24"], "outbound": "direct"],
                    ["domain_suffix": ["openai.com"], "process_name": ["CompanyAgent"], "outbound": "direct"],
                    ["network": "udp", "port": 443, "domain_suffix": ["restricted.example"], "action": "reject"],
                    ["network": "udp", "port": 443, "action": "reject"]
                ]]
            ]
            try JSONSerialization.data(withJSONObject: realFixture).write(to: configURL)
            let real = ConductorController(configPath: configURL.path, singBoxPath: runtime)
            await real.checkRuntime()
            precondition(real.runtimeHealth == .healthy, "Real check requires sing-box 1.14.0")
            let beforeBadURI = try Data(contentsOf: configURL)
            await real.importVLESSURI("vless://00000000-0000-0000-0000-000000000000@192.0.2.1:443?security=reality&security=reality", targetApp: "chatgpt")
            precondition(real.lastError?.contains("重复参数") == true)
            let afterBadURI = try Data(contentsOf: configURL)
            precondition(beforeBadURI == afterBadURI)
            let uri = "vless://00000000-0000-0000-0000-000000000001@192.0.2.1:443?security=reality&flow=xtls-rprx-vision&sni=www.apple.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=1234"
            for suffix in ["&type=ws", "&encryption=other", "&headerType=http", "&spx=%2F", "&unknown", "&type=tcp&type=ws"] {
                let beforeUnsupported = try Data(contentsOf: configURL)
                await real.importVLESSURI(uri + suffix, targetApp: "chatgpt")
                precondition(real.lastError != nil, suffix)
                let afterUnsupported = try Data(contentsOf: configURL)
                precondition(afterUnsupported == beforeUnsupported, suffix)
            }
            var reservedFixture = realFixture
            reservedFixture["outbounds"] = [["type": "direct", "tag": "direct"], ["type": "direct", "tag": "chatgpt-vless"]]
            let reservedData = try JSONSerialization.data(withJSONObject: reservedFixture)
            try reservedData.write(to: configURL)
            await real.importVLESSURI(uri, targetApp: "chatgpt")
            precondition(real.lastError?.contains("标签已被其他类型出口占用") == true)
            let afterReserved = try Data(contentsOf: configURL)
            precondition(afterReserved == reservedData)
            try JSONSerialization.data(withJSONObject: realFixture).write(to: configURL)
            await real.importVLESSURI(uri.replacingOccurrences(of: "vless://", with: "VLESS://") + "&type=tcp&encryption=none&headerType=none", targetApp: "chatgpt")
            precondition(real.lastError == nil, real.lastError ?? "")
            let imported = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
            precondition((imported["outbounds"] as! [[String: Any]]).contains { $0["tag"] as? String == "chatgpt-vless" })
            let importedRoute = imported["route"] as! [String: Any]
            let importedRules = importedRoute["rules"] as! [[String: Any]]
            precondition(importedRoute["final"] as? String == "direct")
            precondition(importedRules.contains { $0["outbound"] as? String == "direct" && $0["ip_cidr"] as? [String] == ["10.247.53.0/24"] })
            precondition(importedRules.contains { $0["outbound"] as? String == "direct" && $0["process_name"] as? [String] == ["CompanyAgent"] })
            let directIndex = importedRules.firstIndex { $0["process_name"] as? [String] == ["CompanyAgent"] }!
            let appIndex = importedRules.firstIndex { $0["outbound"] as? String == "chatgpt-vless" }!
            precondition(directIndex < appIndex)
            precondition(importedRules.contains { $0["outbound"] as? String == "chatgpt-vless" && ($0["process_path"] as? [String])?.contains("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT") == true })
            precondition(importedRules.contains { $0["outbound"] as? String == "chatgpt-vless" && ($0["domain_suffix"] as? [String])?.contains("openai.com") == true })
            var withGoogle = imported
            var googleRoute = importedRoute
            var googleRules = importedRules
            googleRules.append(["outbound": "chatgpt-vless", "domain_suffix": ["google.com"]])
            googleRules.append(["outbound": "chatgpt-vless", "domain_suffix": "openai.com"])
            googleRules.append(["outbound": "chatgpt-vless", "process_name": "ChatGPT"])
            googleRoute["rules"] = googleRules
            withGoogle["route"] = googleRoute
            try JSONSerialization.data(withJSONObject: withGoogle).write(to: configURL)
            await real.importVLESSURI(uri, targetApp: "chatgpt")
            precondition(real.lastError == nil, real.lastError ?? "")
            let replaced = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
            let replacedRules = (replaced["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(replacedRules.contains { $0["outbound"] as? String == "chatgpt-vless" && $0["domain_suffix"] as? [String] == ["google.com"] })
            precondition(!replacedRules.contains { $0["domain_suffix"] as? String == "openai.com" && $0["outbound"] as? String == "chatgpt-vless" })
            precondition(!replacedRules.contains { $0["process_name"] as? String == "ChatGPT" && $0["outbound"] as? String == "chatgpt-vless" })
            precondition(replacedRules.filter { ($0["process_path"] as? [String])?.contains("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT") == true }.count == 1)
            precondition(replacedRules.filter { ($0["domain_suffix"] as? [String])?.contains("openai.com") == true && $0["outbound"] as? String == "chatgpt-vless" }.count == 1)
            precondition(!real.configurationHistory.isEmpty)
            print("Real VLESS import checks passed: duplicate parameter rejected, node imported and backed up")
            await real.saveProxy(tag: "fixture-http", kind: "http", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: false, wasAutoDetected: false)
            precondition(real.lastError == nil, real.lastError ?? "")
            await real.saveProxy(tag: "fixture-http", kind: "http", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: true, excludedProcessPaths: [], supportsUDP: false, wasAutoDetected: false)
            precondition(real.lastError == nil, real.lastError ?? "")
            let savedAgain = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
            let savedRules = (savedAgain["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(savedRules.contains { $0["domain_suffix"] as? [String] == ["restricted.example"] && $0["action"] as? String == "reject" })
            precondition(savedRules.filter { Set($0.keys) == Set(["network", "port", "action"]) && $0["network"] as? String == "udp" && $0["port"] as? Int == 443 && $0["action"] as? String == "reject" }.count == 2)
            await real.saveProxy(tag: "fixture-auth", kind: "socks", endpoint: "127.0.0.1:7890", domains: "auth.example", useAsDefault: false, excludedProcessPaths: [], supportsUDP: true, wasAutoDetected: false, credentials: ("user", "secret"))
            precondition(real.lastError == nil, real.lastError ?? "")
            let authConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
            let authOutbound = (authConfig["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "fixture-auth" }!
            precondition(authOutbound["username"] as? String == "user" && authOutbound["password"] as? String == "secret")
            await real.validateConfiguration()
            precondition(real.lastError == nil, real.lastError ?? "")
            if let appPath = ProcessInfo.processInfo.environment["CONDUCTOR_CHECK_VPN_APP"] {
                let paths = real.executablePaths(inApplication: URL(fileURLWithPath: appPath))
                precondition(paths.contains { $0.hasSuffix("/ApexCore") })
                await real.saveProxy(tag: "fixture-http", kind: "http", endpoint: "127.0.0.1:7890", domains: "", useAsDefault: true, excludedProcessPaths: paths, supportsUDP: false, wasAutoDetected: false)
                precondition(real.lastError == nil, real.lastError ?? "")
                let checkedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
                let checkedRoute = checkedConfig["route"] as! [String: Any]
                let checkedRules = checkedRoute["rules"] as! [[String: Any]]
                precondition(checkedRoute["final"] as? String == "fixture-http")
                precondition(checkedRules.first?["outbound"] as? String == "direct")
                precondition((checkedRules.first?["process_path"] as? [String])?.contains(where: { $0.hasSuffix("/ApexCore") }) == true)
                print("VPN exclusion check passed: ApexCore routes direct before default")
            }
            await real.deleteProxyConfiguration(id: "fixture-http")
            precondition(real.lastError == nil, real.lastError ?? "")
            let afterDelete = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
            let afterDeleteRules = (afterDelete["route"] as! [String: Any])["rules"] as! [[String: Any]]
            precondition(afterDeleteRules.filter { Set($0.keys) == Set(["network", "port", "action"]) && $0["network"] as? String == "udp" && $0["port"] as? Int == 443 && $0["action"] as? String == "reject" }.count == 1)
            guard let previous = real.configurationHistory.first else { fatalError("Missing backup") }
            let beforeRestore = try Data(contentsOf: configURL)
            let expectedRestore = try Data(contentsOf: previous.url)
            let countBeforeRestore = real.configurationHistory.count
            await real.restoreHistory(previous)
            precondition(real.lastError == nil, real.lastError ?? "")
            let restored = try Data(contentsOf: configURL)
            precondition(restored == expectedRestore)
            precondition(real.configurationHistory.count == countBeforeRestore + 1)
            guard let restoreBackup = real.configurationHistory.first(where: { $0.url.lastPathComponent.contains("backup-restore-") }) else { fatalError("Missing restore backup") }
            precondition(restoreBackup.reason == "恢复前备份")
            let permissions = try FileManager.default.attributesOfItem(atPath: restoreBackup.url.path)[.posixPermissions] as? NSNumber
            precondition(permissions?.intValue == 0o600)
            let invalidURL = directory.appendingPathComponent("invalid-history.json")
            try Data("invalid json".utf8).write(to: invalidURL)
            let invalid = ConfigurationHistoryItem(id: invalidURL.path, url: invalidURL, createdAt: Date(), reason: "fixture")
            await real.restoreHistory(invalid)
            precondition(real.lastError != nil)
            let afterInvalidRestore = try Data(contentsOf: configURL)
            precondition(afterInvalidRestore == restored)
            precondition(beforeRestore != restored)
            print("Real restore checks passed: restore, backup, invalid candidate preservation")
            print("Real sing-box 1.14.0 checks passed: HTTP default, UDP reject, deletion")
        }
    }
}
