import WidgetKit
import SwiftUI

private let defaultWidgetURL = URL(string: "http://127.0.0.1")!

struct RateLimitWindow: Codable, Sendable {
    let usedPercent: Double?
    let remainingPercent: Double?
    let windowSeconds: Double?
    let resetAt: String?
    let resetAfterSeconds: Double?
}

struct BalanceAccountResult: Codable, Identifiable {
    var id: String { name }
    let name: String
    let displayName: String?
    let abbreviation: String?
    let remaining: Double?
    let limit: Double?
    let used: Double?
    let unit: String?
    let window: String?
    let status: String
    let message: String?
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?

    init(name: String, remaining: Double?, limit: Double?, used: Double?, unit: String?, window: String?, status: String, message: String?, displayName: String? = nil, abbreviation: String? = nil, primaryWindow: RateLimitWindow? = nil, secondaryWindow: RateLimitWindow? = nil) {
        self.name = name
        self.displayName = displayName
        self.abbreviation = abbreviation
        self.remaining = remaining
        self.limit = limit
        self.used = used
        self.unit = unit
        self.window = window
        self.status = status
        self.message = message
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
    }
}

private extension BalanceAccountResult {
    var displayPrimaryWindow: RateLimitWindow? {
        guard let primaryWindow else { return legacyPrimaryWindow }
        guard let legacy = legacyPrimaryWindow else { return primaryWindow }
        return RateLimitWindow(
            usedPercent: primaryWindow.usedPercent ?? legacy.usedPercent,
            remainingPercent: primaryWindow.remainingPercent ?? legacy.remainingPercent,
            windowSeconds: primaryWindow.windowSeconds ?? legacy.windowSeconds,
            resetAt: primaryWindow.resetAt ?? legacy.resetAt,
            resetAfterSeconds: primaryWindow.resetAfterSeconds ?? legacy.resetAfterSeconds
        )
    }

    var legacyPrimaryWindow: RateLimitWindow? {
        guard let remaining else { return nil }

        let remainingPercent: Double
        let usedPercent: Double?
        if unit == "%" {
            remainingPercent = remaining
            usedPercent = used.map { max(0, min(100, $0)) } ?? max(0, min(100, 100 - remaining))
        } else if let limit, limit > 0 {
            remainingPercent = remaining / limit * 100
            usedPercent = used.map { $0 / limit * 100 } ?? (100 - remainingPercent)
        } else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent.map { max(0, min(100, $0)) },
            remainingPercent: max(0, min(100, remainingPercent)),
            windowSeconds: legacyWindowSeconds,
            resetAt: nil,
            resetAfterSeconds: nil
        )
    }

    private var legacyWindowSeconds: Double? {
        guard let window = window?.lowercased() else { return nil }
        if window == "5h" { return 18_000 }
        if window == "7d" { return 604_800 }
        if window == "30d" { return 2_592_000 }
        if window.hasSuffix("h"), let hours = Double(window.dropLast()) { return hours * 3_600 }
        if window.hasSuffix("d"), let days = Double(window.dropLast()) { return days * 86_400 }
        if window.hasSuffix("m"), let minutes = Double(window.dropLast()) { return minutes * 60 }
        if window.hasSuffix("s"), let seconds = Double(window.dropLast()) { return seconds }
        return nil
    }
}

struct BalanceWidgetData: Codable {
    let updatedAt: Date
    let source: String
    let widgetURL: String
    let accounts: [BalanceAccountResult]
}

struct OpenClawEntry: TimelineEntry {
    let date: Date
    let updatedAt: Date?
    let source: String
    let widgetURL: URL
    let accounts: [BalanceAccountResult]
    let status: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> OpenClawEntry { OpenClawEntry(date: Date(), updatedAt: Date(), source: "Preview", widgetURL: defaultWidgetURL, accounts: sampleAccounts, status: "Preview") }
    func getSnapshot(in context: Context, completion: @escaping (OpenClawEntry) -> Void) { completion(loadEntry(statusIfMissing: "No cached data")) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenClawEntry>) -> Void) {
        let entry = loadEntry(statusIfMissing: "Waiting for background refresh")
        let configuredSeconds = OpenClawWidgetPaths.load()?.behavior?.refreshIntervalSeconds ?? 60
        let interval = TimeInterval(max(60, configuredSeconds))
        let next = Date().addingTimeInterval(interval)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
    private func loadEntry(statusIfMissing: String) -> OpenClawEntry {
        let url = widgetDataURL()
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder.openClaw.decode(BalanceWidgetData.self, from: data) else {
            return OpenClawEntry(date: Date(), updatedAt: nil, source: "missing", widgetURL: configuredWidgetURL, accounts: missingAccounts, status: statusIfMissing)
        }
        let status = decoded.accounts.contains { $0.status != "ok" } ? "stale" : "OK"
        return OpenClawEntry(date: Date(), updatedAt: decoded.updatedAt, source: decoded.source, widgetURL: URL(string: decoded.widgetURL) ?? configuredWidgetURL, accounts: decoded.accounts, status: status)
    }
    private func widgetDataURL() -> URL {
        OpenClawWidgetPaths.resolveCacheURL()
    }
    private var configuredWidgetURL: URL {
        guard let value = OpenClawWidgetPaths.load()?.widgetURL,
              let url = URL(string: value) else { return defaultWidgetURL }
        return url
    }
    private var sampleAccounts: [BalanceAccountResult] {
        let primary = RateLimitWindow(usedPercent: 18, remainingPercent: 82, windowSeconds: 18_000, resetAt: nil, resetAfterSeconds: 4_200)
        let secondary = RateLimitWindow(usedPercent: 31, remainingPercent: 69, windowSeconds: 604_800, resetAt: nil, resetAfterSeconds: 240_000)
        let names = OpenClawWidgetPaths.load()?.accounts.prefix(2).map { ($0.name, $0.displayName ?? $0.name, $0.abbreviation ?? String($0.name.prefix(3))) }
        let fallback = [("Account 1", "Account 1", "A1"), ("Account 2", "Account 2", "A2")]
        let values = (names.map { Array($0) } ?? fallback)
        return values.enumerated().map { index, item in
            BalanceAccountResult(name: item.0, remaining: index == 0 ? 123 : 456, limit: index == 0 ? 300 : 500, used: index == 0 ? 177 : 44, unit: "quota", window: "30d", status: "ok", message: nil, displayName: item.1, abbreviation: item.2, primaryWindow: primary, secondaryWindow: secondary)
        }
    }
    private var missingAccounts: [BalanceAccountResult] {
        let names = OpenClawWidgetPaths.load()?.accounts.prefix(2).map { ($0.name, $0.displayName ?? $0.name, $0.abbreviation ?? String($0.name.prefix(3))) }
        let values = names.map { Array($0) } ?? [("Account 1", "Account 1", "A1"), ("Account 2", "Account 2", "A2")]
        return values.map { item in BalanceAccountResult(name: item.0, remaining: nil, limit: nil, used: nil, unit: nil, window: "30d", status: "missing", message: nil, displayName: item.1, abbreviation: item.2) }
    }
}

struct OpenClawWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumLayout
            } else {
                smallLayout
            }
        }
        .widgetURL(entry.widgetURL)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.15),
                    Color(red: 0.06, green: 0.09, blue: 0.11),
                    Color(red: 0.13, green: 0.15, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            HStack(alignment: .top, spacing: 8) {
                ForEach(displayAccounts) { account in
                    compactMeter(account)
                }
            }

            Spacer(minLength: 0)

            Text(timestampText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mediumLayout: some View {
        GeometryReader { proxy in
            mediumContent(size: proxy.size)
        }
    }

    private func mediumContent(size: CGSize) -> some View {
        let ringSize = mediumRingSize(for: size)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                header
                Spacer(minLength: 8)
                Text(timestampText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            HStack(alignment: .center, spacing: 12) {
                ForEach(displayAccounts) { account in
                    mediumMeter(account, ringSize: ringSize)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: size.width, height: size.height, alignment: .center)
    }

    private func mediumRingSize(for size: CGSize) -> CGFloat {
        let widthBound = (size.width - 48) / 3.25
        let heightBound = size.height - 54
        return min(92, max(80, min(widthBound, heightBound)))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.13), in: Circle())

            Text("Codex 额度")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if family != .systemMedium {
                Spacer(minLength: 4)
                statusDot
            }
        }
    }

    private func compactMeter(_ account: BalanceAccountResult) -> some View {
        VStack(spacing: 5) {
            Text(account.abbreviation ?? account.displayName ?? account.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            ConcentricQuotaRingView(
                primaryWindow: account.displayPrimaryWindow,
                secondaryWindow: account.secondaryWindow,
                size: 60,
                lineWidth: 5
            )

            VStack(spacing: 1) {
                compactWindowMetric(title: "5h", window: account.displayPrimaryWindow)
                compactWindowMetric(title: "7d", window: account.secondaryWindow)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func mediumMeter(_ account: BalanceAccountResult, ringSize: CGFloat) -> some View {
        HStack(spacing: 11) {
            ConcentricQuotaRingView(
                primaryWindow: account.displayPrimaryWindow,
                secondaryWindow: account.secondaryWindow,
                size: ringSize,
                lineWidth: max(7, ringSize * 0.085)
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(account.displayPrimaryWindow.map { windowTint($0) } ?? .orange)
                        .frame(width: 7, height: 7)
                    Text(account.displayName ?? account.name)
                        .font(.system(size: max(12, ringSize * 0.135), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }

                windowMetric(title: "5 小时", window: account.displayPrimaryWindow)
                windowMetric(title: "7 天", window: account.secondaryWindow)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactWindowMetric(title: String, window: RateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(title)
                    .foregroundStyle(.white.opacity(0.55))
                Text(percentText(window))
                    .foregroundStyle(window.map { windowTint($0) } ?? .orange)
            }
            Text(resetText(window, isLongWindow: title == "7d"))
                .foregroundStyle(.white.opacity(0.48))
        }
        .font(.system(size: 9.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private func windowMetric(title: String, window: RateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 2)
                Text(percentText(window))
                    .foregroundStyle(window.map { windowTint($0) } ?? .orange)
            }
            Text("重置 " + resetText(window, isLongWindow: title == "7 天"))
                .foregroundStyle(.white.opacity(0.48))
        }
        .font(.system(size: max(10.5, 12), weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.58)
    }

    private var displayAccounts: [BalanceAccountResult] {
        let accounts = Array(entry.accounts.prefix(2))
        if accounts.isEmpty {
            return [BalanceAccountResult(name: "Codex", remaining: nil, limit: nil, used: nil, unit: nil, window: "30d", status: "missing", message: "Open app", displayName: nil, abbreviation: nil)]
        }
        return accounts
    }

    private var statusDot: some View {
        let healthy = displayAccounts.allSatisfy { $0.status == "ok" && $0.remaining != nil }
        return Circle()
            .fill(healthy ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .accessibilityLabel(entry.status)
    }

    private func percentText(_ window: RateLimitWindow?) -> String {
        guard let window,
              let remaining = window.remainingPercent ?? window.usedPercent.map({ 100 - $0 }) else { return "--" }
        return remaining.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private func windowTint(_ window: RateLimitWindow) -> Color {
        guard let remaining = window.remainingPercent ?? window.usedPercent.map({ 100 - $0 }) else { return .orange }
        if remaining >= 65 { return .green }
        if remaining >= 28 { return .orange }
        return .red
    }

    private func resetText(_ window: RateLimitWindow?, isLongWindow: Bool = false) -> String {
        guard let resetDate = resetDate(for: window) else { return "--" }
        let usesDate = isLongWindow || (window?.windowSeconds ?? 0) >= 172_800
        if usesDate {
            return resetDate.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
        }
        return resetDate.formatted(date: .omitted, time: .shortened)
    }

    private func resetDate(for window: RateLimitWindow?) -> Date? {
        guard let window else { return nil }
        if let resetAt = window.resetAt {
            if let date = parseISO8601(resetAt) { return date }
            if let timestamp = Double(resetAt) { return Date(timeIntervalSince1970: timestamp) }
        }
        guard let updatedAt = entry.updatedAt, let resetAfterSeconds = window.resetAfterSeconds else { return nil }
        return updatedAt.addingTimeInterval(resetAfterSeconds)
    }

    private func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "ok": return "正常"
        case "missing": return "需刷新"
        case "stale": return "缓存"
        case "error": return "异常"
        default: return status
        }
    }

    private var timestampText: String {
        guard let updatedAt = entry.updatedAt else { return statusLabel(entry.status) }
        return "更新 " + updatedAt.formatted(date: .omitted, time: .shortened)
    }
}

private struct ConcentricQuotaRingView: View {
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?
    let size: CGFloat
    let lineWidth: CGFloat

    private var primaryProgress: Double? {
        guard let primaryWindow,
              let remaining = primaryWindow.remainingPercent ?? primaryWindow.usedPercent.map({ 100 - $0 }) else { return nil }
        return max(0, min(1, remaining / 100))
    }

    private var secondaryProgress: Double? {
        guard let secondaryWindow,
              let remaining = secondaryWindow.remainingPercent ?? secondaryWindow.usedPercent.map({ 100 - $0 }) else { return nil }
        return max(0, min(1, remaining / 100))
    }

    private var primaryTint: Color {
        guard let primaryWindow,
              let remaining = primaryWindow.remainingPercent ?? primaryWindow.usedPercent.map({ 100 - $0 }) else { return .orange }
        if remaining >= 65 { return .green }
        if remaining >= 28 { return .orange }
        return .red
    }

    private var secondaryTint: Color {
        guard let secondaryWindow,
              let remaining = secondaryWindow.remainingPercent ?? secondaryWindow.usedPercent.map({ 100 - $0 }) else { return .orange }
        if remaining >= 65 { return .green }
        if remaining >= 28 { return .orange }
        return .red
    }

    private var primaryPercentText: String {
        guard let primaryWindow,
              let remaining = primaryWindow.remainingPercent ?? primaryWindow.usedPercent.map({ 100 - $0 }) else { return "--" }
        return remaining.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private var secondaryPercentText: String {
        guard let secondaryWindow,
              let remaining = secondaryWindow.remainingPercent ?? secondaryWindow.usedPercent.map({ 100 - $0 }) else { return "--" }
        return remaining.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            if let secondaryProgress {
                Circle()
                    .trim(from: 0, to: secondaryProgress)
                    .stroke(secondaryTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: secondaryTint.opacity(0.30), radius: 4, y: 1)
            }

            Circle()
                .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: size * 0.69, height: size * 0.69)

            if let primaryProgress {
                Circle()
                    .trim(from: 0, to: primaryProgress)
                    .stroke(primaryTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: size * 0.69, height: size * 0.69)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: primaryTint.opacity(0.38), radius: 4, y: 1)
            }

            VStack(spacing: 0) {
                Text(primaryPercentText)
                    .font(.system(size: min(18, max(12, size * 0.23)), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("5h")
                    .font(.system(size: min(10, max(8, size * 0.12)), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("5 小时剩余 \(primaryPercentText)，7 天剩余 \(secondaryPercentText)")
    }
}

struct OpenClawWidget: Widget {
    let kind: String = "OpenClawWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in OpenClawWidgetEntryView(entry: entry) }
            .configurationDisplayName("OpenClaw Codex Quota")
            .description("Shows configured Codex accounts and their 5-hour and 7-day quota.")
            .supportedFamilies([.systemSmall, .systemMedium])
            .contentMarginsDisabled()
    }
}

@main
struct OpenClawWidgetBundle: WidgetBundle { var body: some Widget { OpenClawWidget() } }
extension JSONDecoder { static var openClaw: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder } }
