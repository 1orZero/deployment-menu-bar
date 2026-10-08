import SwiftUI

/// Icon, color and label of a deployment state, shared by the app rows, the detail screen and every widget.
struct StateStyle {
    let symbol: String
    let color: Color
    let label: String

    init(_ state: Deployment.State) {
        switch state {
        case .ready:
            self.init(symbol: "checkmark.circle", color: Palette.ready, label: "Ready")
        case .building:
            self.init(symbol: "rays", color: Palette.building, label: "Building")
        case .queued:
            self.init(symbol: "clock", color: Palette.building, label: "Queued")
        case .error:
            self.init(symbol: "xmark.circle", color: Palette.error, label: "Error")
        case .canceled:
            self.init(symbol: "slash.circle", color: Palette.mutedState, label: "Canceled")
        case .skipped:
            self.init(symbol: "forward.circle", color: Palette.mutedState, label: "Skipped")
        case .unknown:
            self.init(symbol: "questionmark.circle", color: Palette.mutedState, label: "Unknown")
        }
    }

    private init(symbol: String, color: Color, label: String) {
        self.symbol = symbol
        self.color = color
        self.label = label
    }
}

extension Deployment.Platform {
    var menuPlatform: MenuPlatform {
        self == .vercel ? .vercel : .cloudflare
    }

    /// SF Symbol drawn in white on the platform badge, matching the Mac menu's ▲ and ☁.
    var symbol: String {
        self == .vercel ? "triangle.fill" : "cloud.fill"
    }

    var badgeColor: Color {
        self == .vercel ? Palette.vercel : Palette.cloudflare
    }

    /// "Pages" or "Workers" for Cloudflare rows; Vercel rows need no product label.
    var productLabel: String? {
        switch self {
        case .vercel: nil
        case .cloudflarePages: "Pages"
        case .cloudflareWorkers: "Workers"
        }
    }
}

extension Deployment {
    /// Second row line: branch, Cloudflare product and source, rollout share and environment, the same parts the Mac
    /// menu lists, joined with " · ".
    var metaLine: String {
        var parts: [String] = []
        if let branch {
            parts.append(branch)
        }
        if let productLabel = platform.productLabel {
            parts.append(productLabel)
        }
        if let sourceLabel {
            parts.append(sourceLabel)
        }
        if let trafficPercentage {
            parts.append("\(trafficPercentage)% rollout")
        }
        // Workers deployments are always production, so the environment would add nothing.
        if platform != .cloudflareWorkers, let environmentLabel {
            parts.append(environmentLabel)
        }
        return parts.joined(separator: " · ")
    }

    var environmentLabel: String? {
        switch environment {
        case .production: "Production"
        case .preview: "Preview"
        case let .custom(name): name.capitalized
        case nil: nil
        }
    }

    /// How long the build ran (finished rows) or has been running (building and queued rows); nil when unknown.
    func duration(now: Date = Date()) -> TimeInterval? {
        switch state {
        case .building:
            return now.timeIntervalSince(buildStartDate)
        case .queued:
            return now.timeIntervalSince(createdAt)
        case .ready, .error, .canceled, .skipped, .unknown:
            return finishedAt.map { max($0.timeIntervalSince(buildStartDate), 0) }
        }
    }

    /// First non-empty line of the commit message, whitespace collapsed.
    var commitTitle: String? {
        let firstLine = commitMessage?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let firstLine else { return nil }
        return firstLine.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    var isInProgress: Bool {
        state == .building || state == .queued
    }
}

enum DeploymentFormat {
    /// "54s", "2m 4s" or "1h 3m 0s", as in the Mac menu.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(remaining)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(remaining)s"
        }
        return "\(remaining)s"
    }

    /// Clock time for today's rows ("14:42"), month and day for older ones ("Oct 6").
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Rounded square with the platform symbol, as in every row of the design.
struct PlatformBadge: View {
    let platform: Deployment.Platform
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: platform.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(platform.badgeColor, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(platform.menuPlatform.name)
    }
}

/// Opens a screen of the app from a widget tap or a link.
enum DeepLink: Equatable {
    case deployment(id: String)
    case iCloudKeychain

    static let scheme = "opendeployment"

    var url: URL {
        switch self {
        case let .deployment(id):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "deployment"
            components.path = "/" + id
            return components.url ?? URL(string: "\(Self.scheme)://deployment")!
        case .iCloudKeychain:
            return URL(string: "\(Self.scheme)://icloud-keychain")!
        }
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "deployment":
            let id = String(url.path.drop { $0 == "/" })
            guard !id.isEmpty else { return nil }
            self = .deployment(id: id)
        case "icloud-keychain":
            self = .iCloudKeychain
        default:
            return nil
        }
    }
}
