import SwiftUI

enum AppTab: Hashable {
    case deployments
    case settings
}

enum SettingsRoute: Hashable {
    case platform(TokenAccount)
    case iCloudKeychain
}

/// First Launch until a token exists, then the Deployments and Settings tabs. Deep links pick the tab and push the
/// screen they name; they are kept while First Launch shows and apply once the tabs appear.
struct RootView: View {
    @EnvironmentObject private var feed: DeploymentFeed
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasStoredToken = RootView.storedTokenExists()
    @State private var selectedTab: AppTab = .deployments
    @State private var deploymentsPath: [String] = []
    @State private var settingsPath: [SettingsRoute] = []

    var body: some View {
        Group {
            if feed.snapshot.hasToken || hasStoredToken {
                tabs
            } else {
                FirstLaunchView(recheckTokens: recheckTokens)
            }
        }
        .onOpenURL { url in
            guard let link = DeepLink(url: url) else { return }
            switch link {
            case let .deployment(id):
                selectedTab = .deployments
                deploymentsPath = [id]
            case .iCloudKeychain:
                selectedTab = .settings
                settingsPath = [.iCloudKeychain]
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recheckTokens()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: PreferencesStore.didChangeNotification).receive(on: RunLoop.main)
        ) { _ in
            recheckTokens()
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $deploymentsPath) {
                DeploymentsView()
                    .navigationDestination(for: String.self) { id in
                        DeploymentDetailView(deploymentID: id)
                    }
            }
            .tabItem { Label("Deployments", systemImage: "paperplane") }
            .tag(AppTab.deployments)

            NavigationStack(path: $settingsPath) {
                SettingsView()
                    .navigationDestination(for: SettingsRoute.self) { route in
                        switch route {
                        case let .platform(account):
                            PlatformSettingsView(account: account)
                        case .iCloudKeychain:
                            ICloudKeychainView()
                        }
                    }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(Palette.accent)
    }

    private func recheckTokens() {
        hasStoredToken = Self.storedTokenExists()
    }

    private static func storedTokenExists() -> Bool {
        TokenAccount.allCases.contains { PreferencesStore.shared.token(for: $0) != nil }
    }
}
