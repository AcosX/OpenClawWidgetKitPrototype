import Foundation

/// Portable configuration shared by the app, widget extension and refresh worker.
/// Secrets are intentionally kept as strings here so callers can move them to
/// Keychain later without changing the public JSON shape.
struct OpenClawWidgetAccount: Codable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let accountID: Int?
    let searchName: String?
    let displayName: String?
    let abbreviation: String?
    let baseURL: String?
    let apiKey: String?
}

struct OpenClawWidgetClickUp: Codable, Sendable {
    let apiKey: String?
    let workspaceId: String?
    let channelId: String?
    let channelName: String?
}

struct OpenClawWidgetConfiguration: Codable, Sendable {
    let schemaVersion: Int
    let backend: Backend
    let bridge: Bridge?
    let accounts: [OpenClawWidgetAccount]
    let clickup: OpenClawWidgetClickUp?
    let widget: Widget
    let behavior: Behavior?

    struct Backend: Codable, Sendable {
        let adminBaseURL: String?
        let adminToken: String?
    }

    struct Bridge: Codable, Sendable {
        let baseURL: String?
        let token: String?
    }

    struct Widget: Codable, Sendable {
        let url: String?
    }

    struct Behavior: Codable, Sendable {
        let refreshIntervalSeconds: Int?
        let maxAccounts: Int?
    }

    // Flat properties preserve the existing WorkerConfig call sites and make
    // migration from sub2api-balance.json transparent.
    var adminBaseURL: String? { backend.adminBaseURL }
    var adminToken: String? { backend.adminToken }
    var bridgeBaseURL: String? { bridge?.baseURL }
    var bridgeToken: String? { bridge?.token }
    var widgetURL: String? { widget.url }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, backend, bridge, accounts, clickup, widget, behavior
        case adminBaseURL, adminToken, widgetURL, bridgeBaseURL, bridgeToken
    }

    init(schemaVersion: Int = 1, backend: Backend, bridge: Bridge? = nil,
         accounts: [OpenClawWidgetAccount], clickup: OpenClawWidgetClickUp? = nil,
         widget: Widget = Widget(url: nil), behavior: Behavior? = nil) {
        self.schemaVersion = schemaVersion
        self.backend = backend
        self.bridge = bridge
        self.accounts = accounts
        self.clickup = clickup
        self.widget = widget
        self.behavior = behavior
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        if let value = try c.decodeIfPresent(Backend.self, forKey: .backend) {
            backend = value
        } else {
            backend = Backend(
                adminBaseURL: try c.decodeIfPresent(String.self, forKey: .adminBaseURL),
                adminToken: try c.decodeIfPresent(String.self, forKey: .adminToken)
            )
        }
        if let value = try c.decodeIfPresent(Bridge.self, forKey: .bridge) {
            bridge = value
        } else if c.contains(.bridgeBaseURL) || c.contains(.bridgeToken) {
            bridge = Bridge(
                baseURL: try c.decodeIfPresent(String.self, forKey: .bridgeBaseURL),
                token: try c.decodeIfPresent(String.self, forKey: .bridgeToken)
            )
        } else {
            bridge = nil
        }
        accounts = try c.decodeIfPresent([OpenClawWidgetAccount].self, forKey: .accounts) ?? []
        clickup = try c.decodeIfPresent(OpenClawWidgetClickUp.self, forKey: .clickup)
        if let value = try c.decodeIfPresent(Widget.self, forKey: .widget) {
            widget = value
        } else {
            widget = Widget(url: try c.decodeIfPresent(String.self, forKey: .widgetURL))
        }
        behavior = try c.decodeIfPresent(Behavior.self, forKey: .behavior)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(bridge, forKey: .bridge)
        try c.encode(accounts, forKey: .accounts)
        try c.encodeIfPresent(clickup, forKey: .clickup)
        try c.encode(widget, forKey: .widget)
        try c.encodeIfPresent(behavior, forKey: .behavior)
    }
}

struct OpenClawWidgetPaths: Sendable {
    static let appGroupIdentifier = "group.local.openclaw.WidgetKitPrototype"
    static let configFileName = "openclaw-widget.json"
    static let legacyConfigFileName = "sub2api-balance.json"
    static let fallbackDirectoryName = ".config/openclaw-widgetkitprototype"
    /// Compatibility path for the pre-portable sandbox entitlement. It is
    /// derived from the current username rather than embedding a developer path.
    static var legacyDirectory: URL {
        URL(fileURLWithPath: "/Users", isDirectory: true)
            .appendingPathComponent(NSUserName(), isDirectory: true)
            .appendingPathComponent(".config/openclaw", isDirectory: true)
    }

    let configURL: URL
    /// Runtime state is always kept in the shared data directory. The config
    /// file may be selected from anywhere with `--config`, but that must not
    /// redirect status/cache/outbox files into an arbitrary parent directory.
    private let dataDirectory: URL
    var directory: URL { dataDirectory }
    var cacheURL: URL { directory.appendingPathComponent("sub2api-widget-data.json") }
    var statusURL: URL { directory.appendingPathComponent("sub2api-refresh-status.json") }
    var outboxURL: URL { directory.appendingPathComponent("sub2api-clickup-outbox.json") }
    var receiptsURL: URL { directory.appendingPathComponent("sub2api-clickup-receipts.json") }
    var testResultURL: URL { directory.appendingPathComponent("sub2api-clickup-test-result.json") }
    var logURL: URL { directory.appendingPathComponent("sub2api-refresh-worker.log") }
    var lockURL: URL { directory.appendingPathComponent("sub2api-refresh-worker.lock") }

    init(configURL: URL, dataDirectory: URL? = nil) {
        self.configURL = configURL
        self.dataDirectory = dataDirectory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return shared.appendingPathComponent("Config", isDirectory: true)
        }
        // Keep unsigned/development builds isolated from the legacy installed
        // app. The old directory remains a read-only migration source below.
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallbackDirectoryName, isDirectory: true)
    }

    static func resolveConfigURL(explicit: URL? = nil) -> URL {
        if let explicit { return explicit }
        let portable = defaultDirectory()
        let candidates = [
            portable.appendingPathComponent(configFileName),
            portable.appendingPathComponent(legacyConfigFileName),
            legacyDirectory.appendingPathComponent(configFileName),
            legacyDirectory.appendingPathComponent(legacyConfigFileName)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? portable.appendingPathComponent(configFileName)
    }

    static func resolveCacheURL() -> URL {
        let portable = defaultDirectory().appendingPathComponent("sub2api-widget-data.json")
        if FileManager.default.fileExists(atPath: portable.path) { return portable }
        // Read compatibility for the old unsandboxed installation, while all
        // new writes continue to use the shared runtime directory.
        let legacy = legacyDirectory.appendingPathComponent("sub2api-widget-data.json")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : portable
    }

    static func load() -> OpenClawWidgetConfiguration? {
        let url = resolveConfigURL()
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(OpenClawWidgetConfiguration.self, from: data) else { return nil }
        return config
    }
}
