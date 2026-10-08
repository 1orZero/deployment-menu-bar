import SwiftUI

/// Screen E: the tokens in iCloud Keychain, which the Mac app shares, and a way to remove them everywhere.
struct ICloudKeychainView: View {
    struct SyncedToken: Identifiable {
        let account: TokenAccount
        let suffix: String
        let modifiedAt: Date?

        var id: TokenAccount { account }
    }

    @State private var tokens: [SyncedToken] = []
    @State private var isConfirmingRemoval = false
    @State private var removalError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero

                VStack(spacing: 8) {
                    SectionTitle(text: "Synced Tokens")
                    Card {
                        if tokens.isEmpty {
                            Text("No tokens yet. Add one in Settings or on your Mac.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            ForEach(Array(tokens.enumerated()), id: \.element.id) { index, token in
                                if index > 0 {
                                    RowDivider()
                                }
                                tokenRow(token)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Token missing on one device?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(
                        "Turn on Passwords & Keychain in iCloud settings on both your Mac and iPhone, signed in to the same Apple Account."
                    )
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 8)

                if let removalError {
                    Text(removalError)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Text("Remove Tokens from All Devices")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.error)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(tokens.isEmpty)
            .opacity(tokens.isEmpty ? 0.4 : 1)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Palette.background)
        .navigationTitle("iCloud Keychain")
        .confirmationDialog(
            "Remove tokens from all devices?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Tokens", role: .destructive, action: removeTokens)
        } message: {
            Text("The Vercel and Cloudflare tokens are deleted from iCloud Keychain on this iPhone and on your Mac.")
        }
        .onAppear(perform: reload)
        .onReceive(
            NotificationCenter.default.publisher(for: PreferencesStore.didChangeNotification).receive(on: RunLoop.main)
        ) { _ in
            reload()
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                deviceCircle("laptopcomputer")
                Image(systemName: "arrow.left.arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
                deviceCircle("iphone")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Tokens sync through iCloud")
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                Text("Editing a token here or on your Mac updates both.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    private func deviceCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: 44, height: 44)
            .background(Palette.chip, in: Circle())
    }

    private func tokenRow(_ token: SyncedToken) -> some View {
        HStack(spacing: 12) {
            PlatformBadge(platform: token.account.platform, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(token.account.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("•••• \(token.suffix)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(Palette.ready)
                if let modifiedAt = token.modifiedAt {
                    Text(DeploymentFormat.time(modifiedAt))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        let keychain = KeychainTokenStore()
        tokens = TokenAccount.allCases.compactMap { account in
            guard let token = PreferencesStore.shared.token(for: account), !token.isEmpty else { return nil }
            return SyncedToken(
                account: account,
                suffix: String(token.suffix(4)),
                modifiedAt: keychain.modificationDate(for: account)
            )
        }
    }

    private func removeTokens() {
        var failures: [String] = []
        for account in TokenAccount.allCases {
            do {
                try PreferencesStore.shared.setToken("", for: account)
            } catch {
                failures.append("\(account.name): \(error.localizedDescription)")
            }
        }
        removalError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        reload()
    }
}
