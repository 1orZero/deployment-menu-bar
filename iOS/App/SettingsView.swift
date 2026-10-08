import SwiftUI

/// Screen C: platform connections, iCloud Keychain sync, list layout and the app version.
struct SettingsView: View {
    @EnvironmentObject private var feed: DeploymentFeed
    @State private var layout = PreferencesStore.shared.current.general.menuLayout
    @State private var storedTokens: Set<TokenAccount> = SettingsView.loadStoredTokens()

    var body: some View {
        List {
            Section("Platforms") {
                ForEach(TokenAccount.allCases, id: \.self) { account in
                    NavigationLink(value: SettingsRoute.platform(account)) {
                        HStack(spacing: 12) {
                            PlatformBadge(platform: account.platform, size: 30)
                            Text(account.name)
                            Spacer()
                            platformStatus(for: account)
                        }
                    }
                }
            }
            .listRowBackground(Palette.surface)

            Section("Sync") {
                NavigationLink(value: SettingsRoute.iCloudKeychain) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8.4, style: .continuous))
                        Text("iCloud Keychain")
                        Spacer()
                        StatusDot(
                            text: storedTokens.isEmpty ? "No tokens" : "\(storedTokens.count) synced",
                            color: storedTokens.isEmpty ? nil : Palette.ready
                        )
                    }
                }
            }
            .listRowBackground(Palette.surface)

            Section("Display") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("List Layout")
                    Picker("List Layout", selection: $layout) {
                        Text("By Time").tag(MenuLayout.byTime)
                        Text("By Platform").tag(MenuLayout.byPlatform)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Palette.surface)

            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
            .listRowBackground(Palette.surface)
        }
        .appListStyle()
        .navigationTitle("Settings")
        .onChange(of: layout) { _, newValue in
            guard PreferencesStore.shared.current.general.menuLayout != newValue else { return }
            PreferencesStore.shared.update { $0.general.menuLayout = newValue }
        }
        .onAppear(perform: reload)
        .onReceive(
            NotificationCenter.default.publisher(for: PreferencesStore.didChangeNotification).receive(on: RunLoop.main)
        ) { _ in
            reload()
        }
    }

    @ViewBuilder
    private func platformStatus(for account: TokenAccount) -> some View {
        let status = account == .vercel ? feed.snapshot.vercel : feed.snapshot.cloudflare
        if !storedTokens.contains(account) {
            StatusDot(text: "Not set", color: nil)
        } else if status.isEnabled, status.issue != nil {
            StatusDot(text: "Error", color: Palette.error)
        } else {
            StatusDot(text: "Connected", color: Palette.ready)
        }
    }

    private func reload() {
        layout = PreferencesStore.shared.current.general.menuLayout
        storedTokens = Self.loadStoredTokens()
    }

    private static func loadStoredTokens() -> Set<TokenAccount> {
        Set(TokenAccount.allCases.filter { PreferencesStore.shared.token(for: $0) != nil })
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}
