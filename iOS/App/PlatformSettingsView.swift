import SwiftUI

/// Screen D: one platform's token, scope, filters and refresh intervals. Every field saves as it changes, like the
/// Mac Preferences window, through the shared `PreferencesViewModel`.
struct PlatformSettingsView: View {
    let account: TokenAccount

    // Created when the screen opens: it reads the stored values and looks up scopes and projects for the token.
    @StateObject private var model = PreferencesViewModel(store: .shared)

    var body: some View {
        Group {
            switch account {
            case .vercel:
                VercelSettingsForm(model: model)
            case .cloudflare:
                CloudflareSettingsForm(model: model, filters: model.cloudflareFilters)
            }
        }
        .appListStyle()
        .navigationTitle(account.name)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: Keyboard.dismiss)
            }
        }
    }
}

// MARK: - Vercel

private struct VercelSettingsForm: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        List {
            TokenSection(
                token: $model.vercelToken,
                createTitle: "Create Token on vercel.com",
                createURL: URL(string: "https://vercel.com/account/tokens")!,
                errorMessage: model.tokenErrorMessage
            )

            Section("Scope") {
                NavigationLink {
                    VercelScopesList(model: model)
                } label: {
                    LabeledContent("Scopes", value: selectionSummary(
                        isAll: model.teamSelectionMode == .allAccessible, count: model.selectedTeamScopeIDs.count
                    ))
                }
                NavigationLink {
                    VercelProjectsList(model: model)
                } label: {
                    LabeledContent("Projects", value: selectionSummary(
                        isAll: model.projectSelectionMode == .allAccessible, count: model.selectedProjectNames.count
                    ))
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                BranchesRow(text: $model.gitBranches)
                PlatformToggle(title: "Production", isOn: $model.showProduction)
                PlatformToggle(title: "Preview", isOn: $model.showPreview)
                StateChips(chips: [
                    StateChip(title: "Ready", isOn: $model.showReady),
                    StateChip(title: "Building", isOn: $model.showBuilding),
                    StateChip(title: "Error", isOn: $model.showError),
                    StateChip(title: "Queued", isOn: $model.showQueued),
                    StateChip(title: "Canceled", isOn: $model.showCanceled),
                ])
                NumberFieldRow(title: "Latest", text: $model.limitByCount, placeholder: "No limit", unit: "deployments")
                NumberFieldRow(title: "Within", text: $model.limitByHours, placeholder: "No limit", unit: "hours")
            } header: {
                Text("Filters")
            } footer: {
                Text("Branches are comma separated; leave empty for all. When both limits are set, the count wins.")
            }
            .listRowBackground(Palette.surface)

            Section("Refresh") {
                NumberFieldRow(title: "When idle", text: $model.refreshIntervalIdle, placeholder: "15", unit: "s")
                NumberFieldRow(title: "While building", text: $model.refreshIntervalBuilding, placeholder: "2", unit: "s")
            }
            .listRowBackground(Palette.surface)
        }
    }
}

private struct VercelScopesList: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        SelectionList(
            title: "Scopes",
            hasToken: model.hasToken,
            selectsAll: Binding(
                get: { model.teamSelectionMode == .allAccessible },
                set: { model.teamSelectionMode = $0 ? .allAccessible : .selected }
            ),
            isLoading: model.teamsLoading,
            errorMessage: model.optionsErrorMessage,
            emptyMessage: "No scopes found.",
            options: model.availableTeamScopes.map { scope in
                SelectionOption(
                    id: scope.id,
                    title: scope.title,
                    subtitle: scope.subtitle,
                    isSelected: model.teamSelectionBinding(for: scope.id)
                )
            }
        )
    }
}

private struct VercelProjectsList: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        SelectionList(
            title: "Projects",
            hasToken: model.hasToken,
            selectsAll: Binding(
                get: { model.projectSelectionMode == .allAccessible },
                set: { model.projectSelectionMode = $0 ? .allAccessible : .selected }
            ),
            isLoading: model.projectsLoading,
            errorMessage: model.optionsErrorMessage,
            emptyMessage: "No projects found in the selected scopes.",
            options: model.availableProjects.map { project in
                SelectionOption(
                    id: project.id,
                    title: project.name,
                    subtitle: nil,
                    isSelected: model.projectSelectionBinding(for: project.name)
                )
            }
        )
    }
}

// MARK: - Cloudflare

private struct CloudflareSettingsForm: View {
    @ObservedObject var model: PreferencesViewModel
    @ObservedObject var filters: CloudflareFiltersModel

    var body: some View {
        List {
            TokenSection(
                token: $model.cloudflareToken,
                createTitle: "Create Token on Cloudflare",
                createURL: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!,
                errorMessage: model.cloudflareTokenErrorMessage
            )

            Section("Scope") {
                NavigationLink {
                    CloudflareAccountsList(filters: filters)
                } label: {
                    LabeledContent("Accounts", value: selectionSummary(
                        isAll: filters.accountSelectionMode == .allAccessible, count: filters.selectedAccountIDs.count
                    ))
                }
                NavigationLink {
                    CloudflareProjectsList(filters: filters)
                } label: {
                    LabeledContent("Projects", value: selectionSummary(
                        isAll: filters.projectSelectionMode == .allAccessible, count: filters.selectedProjects.count
                    ))
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                BranchesRow(text: $filters.gitBranches)
                PlatformToggle(title: "Production", isOn: $filters.showProduction)
                PlatformToggle(title: "Preview", isOn: $filters.showPreview)
                StateChips(chips: [
                    StateChip(title: "Ready", isOn: $filters.showReady),
                    StateChip(title: "Building", isOn: $filters.showBuilding),
                    StateChip(title: "Error", isOn: $filters.showError),
                    StateChip(title: "Queued", isOn: $filters.showQueued),
                    StateChip(title: "Canceled", isOn: $filters.showCanceled),
                    StateChip(title: "Skipped", isOn: $filters.showSkipped),
                ])
                NumberFieldRow(title: "Latest", text: $filters.limitByCount, placeholder: "No limit", unit: "deployments")
                NumberFieldRow(title: "Within", text: $filters.limitByHours, placeholder: "No limit", unit: "hours")
            } header: {
                Text("Filters")
            } footer: {
                Text("Branches are comma separated; leave empty for all. When both limits are set, the count wins.")
            }
            .listRowBackground(Palette.surface)

            Section {
                NumberFieldRow(
                    title: "Full refresh",
                    text: $model.cloudflareRefreshInterval,
                    placeholder: String(CloudflarePreferences.default.refreshInterval),
                    unit: "s"
                )
                NumberFieldRow(
                    title: "In-progress check",
                    text: $model.cloudflareFastRefreshInterval,
                    placeholder: String(CloudflarePreferences.default.fastRefreshInterval),
                    unit: "s"
                )
            } header: {
                Text("Refresh")
            } footer: {
                Text(
                    "At least \(CloudflarePreferences.minimumRefreshInterval)s and "
                        + "\(CloudflarePreferences.minimumFastRefreshInterval)s, to stay within Cloudflare's rate limit."
                )
            }
            .listRowBackground(Palette.surface)
        }
    }
}

private struct CloudflareAccountsList: View {
    @ObservedObject var filters: CloudflareFiltersModel

    var body: some View {
        SelectionList(
            title: "Accounts",
            hasToken: filters.hasToken,
            selectsAll: Binding(
                get: { filters.accountSelectionMode == .allAccessible },
                set: { filters.accountSelectionMode = $0 ? .allAccessible : .selected }
            ),
            isLoading: filters.isLoading,
            errorMessage: filters.errorMessage,
            emptyMessage: "No accounts found.",
            options: filters.availableAccounts.map { account in
                SelectionOption(
                    id: account.id,
                    title: account.title,
                    subtitle: nil,
                    isSelected: Binding(
                        get: { filters.selectedAccountIDs.contains(account.id) },
                        set: { isSelected in
                            if isSelected {
                                filters.selectedAccountIDs.insert(account.id)
                            } else {
                                filters.selectedAccountIDs.remove(account.id)
                            }
                        }
                    )
                )
            }
        )
    }
}

private struct CloudflareProjectsList: View {
    @ObservedObject var filters: CloudflareFiltersModel

    var body: some View {
        SelectionList(
            title: "Projects",
            hasToken: filters.hasToken,
            selectsAll: Binding(
                get: { filters.projectSelectionMode == .allAccessible },
                set: { filters.projectSelectionMode = $0 ? .allAccessible : .selected }
            ),
            isLoading: filters.isLoading,
            errorMessage: filters.errorMessage,
            emptyMessage: "No Pages projects or Workers found in the selected accounts.",
            options: filters.availableProjects.map { project in
                SelectionOption(
                    id: "\(project.accountID)/\(project.kind.rawValue)/\(project.name)",
                    title: project.name,
                    subtitle: [project.kind == .pages ? "Pages" : "Workers", filters.accountTitle(for: project.accountID)]
                        .compactMap { $0 }
                        .joined(separator: " · "),
                    isSelected: Binding(
                        get: { filters.selectedProjects.contains(project) },
                        set: { isSelected in
                            if isSelected {
                                filters.selectedProjects.insert(project)
                            } else {
                                filters.selectedProjects.remove(project)
                            }
                        }
                    )
                )
            }
        )
    }
}

// MARK: - Shared rows

private func selectionSummary(isAll: Bool, count: Int) -> String {
    isAll ? "All accessible" : "\(count) selected"
}

private struct TokenSection: View {
    @Binding var token: String
    let createTitle: String
    let createURL: URL
    let errorMessage: String?

    @State private var isRevealed = false

    private var hasToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section("API Token") {
            HStack(spacing: 12) {
                Group {
                    if isRevealed {
                        TextField("Paste token", text: $token)
                    } else {
                        SecureField("Paste token", text: $token)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .font(.body.monospaced())

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? "Hide token" : "Show token")
            }

            if hasToken {
                Label {
                    Text("Synced with iCloud Keychain")
                        .foregroundStyle(Palette.textSecondary)
                } icon: {
                    Image(systemName: "checkmark.icloud")
                        .foregroundStyle(Palette.ready)
                }
                .font(.subheadline)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
            }

            Link(destination: createURL) {
                HStack {
                    Text(createTitle)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Palette.accent)
            }
        }
        .listRowBackground(Palette.surface)
    }
}

private struct BranchesRow: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("Branches")
            TextField("All branches", text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Palette.textSecondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
    }
}

private struct PlatformToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .tint(Palette.ready)
    }
}

private struct StateChip: Identifiable {
    let title: String
    let isOn: Binding<Bool>

    var id: String { title }
}

private struct StateChips: View {
    let chips: [StateChip]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("States")
            FlowLayout(spacing: 8) {
                ForEach(chips) { chip in
                    let isOn = chip.isOn.wrappedValue
                    Button {
                        chip.isOn.wrappedValue.toggle()
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? Palette.accent : Palette.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(isOn ? Palette.accentSoft : Palette.chip, in: Capsule())
                            .overlay(Capsule().strokeBorder(isOn ? Palette.accent : Palette.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NumberFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            TextField(placeholder, text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: 90)
                .onChange(of: text) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue {
                        text = digits
                    }
                }
            Text(unit)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct SelectionOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let isSelected: Binding<Bool>
}

/// "All accessible" or a hand-picked subset of the options looked up from the token.
private struct SelectionList: View {
    let title: String
    let hasToken: Bool
    @Binding var selectsAll: Bool
    let isLoading: Bool
    let errorMessage: String?
    let emptyMessage: String
    let options: [SelectionOption]

    var body: some View {
        List {
            Section {
                Picker(title, selection: $selectsAll) {
                    Text("All accessible").tag(true)
                    Text("Selected").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            .listRowBackground(Palette.surface)

            if !selectsAll {
                Section {
                    if !hasToken {
                        Text("Add a token to choose \(title.lowercased()).")
                            .foregroundStyle(Palette.textSecondary)
                    } else if isLoading, options.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading…")
                                .foregroundStyle(Palette.textSecondary)
                        }
                    } else if options.isEmpty {
                        Text(errorMessage == nil ? emptyMessage : "Could not load \(title.lowercased()).")
                            .foregroundStyle(Palette.textSecondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                option.isSelected.wrappedValue.toggle()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title)
                                            .foregroundStyle(Palette.textPrimary)
                                        if let subtitle = option.subtitle, !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(.footnote)
                                                .foregroundStyle(Palette.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if option.isSelected.wrappedValue {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Palette.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(option.isSelected.wrappedValue ? .isSelected : [])
                        }
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Palette.error)
                    } else if isLoading, !options.isEmpty {
                        Text("Refreshing…")
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .appListStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
