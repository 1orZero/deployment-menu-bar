import Foundation

/// A platform as the dropdown groups it; Pages and Workers rows both belong to Cloudflare.
enum MenuPlatform: Equatable {
    case vercel
    case cloudflare

    var name: String {
        switch self {
        case .vercel:
            return "Vercel"
        case .cloudflare:
            return "Cloudflare"
        }
    }
}

/// One dropdown item above the shared footer, independent of AppKit.
enum MenuEntry: Equatable {
    /// Plain informational text such as "No deployments found".
    case notice(String)
    /// ⚠ explanation of a platform issue.
    case banner(String)
    /// Disabled title naming a By Platform section.
    case header(String)
    case deployment(Deployment)
    case dashboard(MenuPlatform)
    case separator
}

/// What the dropdown shows for the current platforms and layout.
struct MenuComposition: Equatable {
    /// Items above the footer.
    var entries: [MenuEntry]
    /// Dashboard items listed in the footer, between Refresh Now and Preferences….
    var footerDashboards: [MenuPlatform]

    static let noTokenMessage = "Add a Vercel or Cloudflare token in Preferences"
    static let noDeploymentsMessage = "No deployments found"

    init(layout: MenuLayout, vercel: PlatformStatus, cloudflare: PlatformStatus) {
        let platforms = [(MenuPlatform.vercel, vercel), (MenuPlatform.cloudflare, cloudflare)]
        let enabled = platforms.filter { $0.1.isEnabled }

        guard !enabled.isEmpty else {
            entries = [.notice(Self.noTokenMessage), .separator]
            footerDashboards = platforms.map(\.0)
            return
        }

        switch layout {
        case .byTime:
            let banners = enabled.compactMap { platform, status in
                status.issue.map { MenuEntry.banner("\(platform.name): \($0.message)") }
            }
            let rows = Deployment.mergedNewestFirst(vercel.deployments, cloudflare.deployments)

            entries = banners
            if !banners.isEmpty {
                entries.append(.separator)
            }
            if rows.isEmpty {
                if banners.isEmpty {
                    entries.append(.notice(Self.noDeploymentsMessage))
                }
            } else {
                entries += rows.map(MenuEntry.deployment)
            }
            footerDashboards = platforms.map(\.0)

        case .byPlatform:
            entries = []
            for (index, (platform, status)) in enabled.enumerated() {
                if index > 0 {
                    entries.append(.separator)
                }
                entries.append(.header(platform.name))
                if let issue = status.issue {
                    entries.append(.banner(issue.message))
                }
                let rows = Deployment.mergedNewestFirst(status.deployments)
                if rows.isEmpty {
                    if status.issue == nil {
                        entries.append(.notice(Self.noDeploymentsMessage))
                    }
                } else {
                    entries += rows.map(MenuEntry.deployment)
                }
                entries.append(.dashboard(platform))
            }
            footerDashboards = []
        }
    }
}
