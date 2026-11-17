import Foundation

enum ControlSection: String, CaseIterable, Identifiable {
    case configuration = "配置"
    case companyVPN = "公司 VPN"
    case settings = "设置"
    case logs = "日志"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .configuration: "slider.horizontal.3"
        case .companyVPN: "building.2"
        case .settings: "gearshape"
        case .logs: "text.alignleft"
        }
    }
}

enum HealthState: String {
    case unknown = "未测试"
    case checking = "检查中"
    case healthy = "正常"
    case warning = "警告"
    case failed = "不可用"

    var symbol: String {
        switch self {
        case .unknown: "circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

struct ProxyConfiguration: Identifiable, Equatable {
    let id: String
    let type: String
    let name: String
    let endpoint: String
    let bindingSummary: String
    let sourceSummary: String?
    var health: HealthState = .unknown
}

struct MixedProxyProbeResult: Equatable, Sendable {
    let httpAvailable: Bool
    let socksTCPAvailable: Bool
    let socksUDPAvailable: Bool

    var selectedKind: String? {
        if socksTCPAvailable { return "socks" }
        if httpAvailable { return "http" }
        return nil
    }

    var supportsUDP: Bool { selectedKind == "socks" && socksUDPAvailable }
}

enum ProxyRouteScope: String, CaseIterable, Identifiable {
    case domains = "指定域名"
    case cidrs = "指定 IP/CIDR"
    case applications = "指定应用"
    case remaining = "剩余流量"

    var id: Self { self }
}

enum CompanyVPNState: String {
    case disconnected = "未连接"
    case connected = "已连接"
    case uncertain = "未确认"
    case failed = "检查失败"
}

struct CompanyVPNObservation: Identifiable, Equatable {
    let id: String
    let name: String
    let processPattern: String
    var state: CompanyVPNState
    var interfaceName: String?
    var networks: [String]
    var evidence: String
    var checkedAt: Date?
}

struct ConfigurationHistoryItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let createdAt: Date
    let reason: String
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case vless = "VLESS"
    case localProxy = "本地代理"
    case companyVPN = "公司 VPN"
    case direct = "Direct"
    case errors = "Warning/Error"

    var id: Self { self }
}
