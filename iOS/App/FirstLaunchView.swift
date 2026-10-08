import SwiftUI

/// Screen F: shown until a token exists. Tokens saved on the Mac arrive through iCloud Keychain at any time, so the
/// keychain is checked every few seconds while this screen is visible.
struct FirstLaunchView: View {
    let recheckTokens: () -> Void

    @State private var editingAccount: TokenAccount?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 96, height: 96)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                    .padding(.bottom, 10)
                    .accessibilityHidden(true)

                Text("Waiting for your tokens")
                    .font(.title.bold())
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Tokens saved on your Mac appear here automatically through iCloud Keychain.")
                    .font(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.accent)
                    Text("Checking iCloud Keychain…")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Palette.surface, in: Capsule())
                .padding(.top, 16)
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    editingAccount = .vercel
                } label: {
                    Label("Add Vercel Token", systemImage: "triangle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.vercel, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                }

                Button {
                    editingAccount = .cloudflare
                } label: {
                    Label {
                        Text("Add Cloudflare Token")
                            .foregroundStyle(Palette.textPrimary)
                    } icon: {
                        Image(systemName: "cloud")
                            .foregroundStyle(Palette.cloudflare)
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .sheet(item: $editingAccount) { account in
            TokenEntrySheet(account: account, onSave: recheckTokens)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                recheckTokens()
            }
        }
    }
}

extension TokenAccount: Identifiable {
    var id: String { rawValue }
}

private struct TokenEntrySheet: View {
    let account: TokenAccount
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecureField("Paste token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(.body.monospaced())
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("API Token")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Palette.error)
                    } else {
                        Text("Saved to iCloud Keychain, so your Mac gets it too.")
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .appListStyle()
            .navigationTitle("\(account.name) Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        do {
            try PreferencesStore.shared.setToken(trimmed, for: account)
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
