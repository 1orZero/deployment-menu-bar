import AppKit
import Combine
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let viewModel: PreferencesViewModel

    private init() {
        let viewModel = PreferencesViewModel(store: PreferencesStore.shared)
        self.viewModel = viewModel
        let view = PreferencesView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Open Deployment Menu Bar Preferences"
        window.contentViewController = hostingController
        super.init(window: window)
        self.window?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        viewModel.reset()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        viewModel.saveAndClose()
    }
}

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralPreferencesTab(viewModel: viewModel)
                    .tabItem { Text("General") }
                VercelPreferencesTab(viewModel: viewModel)
                    .tabItem { Text("Vercel") }
                CloudflarePreferencesTab(viewModel: viewModel, filters: viewModel.cloudflareFilters)
                    .tabItem { Text("Cloudflare") }
            }
            .padding([.top, .horizontal])

            HStack {
                Text("Changes auto-save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    PreferencesWindowController.shared.close()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GeneralPreferencesTab: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Menu Layout", selection: $viewModel.menuLayout) {
                        Text("By Time").tag(MenuLayout.byTime)
                        Text("By Platform").tag(MenuLayout.byPlatform)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                MenuBarDisplaySection(display: $viewModel.menuBar)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
            }
            .padding()
        }
    }
}

/// The menu bar item drawn large. Each part is a toggle, so the preview is also the control.
private struct MenuBarDisplaySection: View {
    @Binding var display: MenuBarDisplay

    private static let sampleProjectName = "storefront-web"
    /// The slider's last step, past the longest length, stands for the whole name.
    private static let fullNameStep = Double(MenuBarDisplay.projectNameLengthRange.upperBound + 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Menu Bar")
                .font(.headline)

            HStack(spacing: 8) {
                part("Platform Icon", isOn: $display.showsPlatformIcon) {
                    Image(systemName: "triangle.fill")
                }
                part("Status Icon", isOn: $display.showsStatusIcon) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                }
                part("Project Name", isOn: $display.showsProjectName) {
                    Text(display.projectLabel(for: Self.sampleProjectName))
                }
                part("Build Time", isOn: $display.showsBuildTime) {
                    Text(display.buildTimeStyle == .compact ? "2m" : "2m 4s")
                }
            }
            .font(.system(size: 18, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.48, green: 0.31, blue: 0.43), Color(red: 0.17, green: 0.23, blue: 0.4)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 8)
            )

            Divider()

            HStack {
                Text("Name Length")
                Spacer()
                Slider(value: nameLengthStep, in: Double(MenuBarDisplay.projectNameLengthRange.lowerBound)...Self.fullNameStep, step: 1) {
                    Text("Name Length")
                }
                .labelsHidden()
                .frame(width: 220)
                .accessibilityValue(nameLengthText)
                Text(nameLengthText)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            .disabled(!display.showsProjectName)

            Divider()

            HStack {
                Text("Build Time")
                Spacer()
                Picker("Build Time", selection: $display.buildTimeStyle) {
                    Text("2m 4s").tag(BuildTimeStyle.full)
                    Text("2m").tag(BuildTimeStyle.compact)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!display.showsBuildTime)
        }
    }

    private var nameLengthStep: Binding<Double> {
        Binding(
            get: { display.projectNameLength == 0 ? Self.fullNameStep : Double(display.projectNameLength) },
            set: { display.projectNameLength = $0 >= Self.fullNameStep ? 0 : Int($0) }
        )
    }

    private var nameLengthText: String {
        display.projectNameLength == 0 ? "Full" : String(display.projectNameLength)
    }

    private func part<Content: View>(
        _ name: String,
        isOn: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Toggle(isOn: isOn, label: content)
            .toggleStyle(MenuBarPartToggleStyle())
            // The last visible part stays on, or the app would vanish from the menu bar.
            .disabled(isOn.wrappedValue && display.visiblePartCount == 1)
            .accessibilityLabel(name)
            .help(isOn.wrappedValue ? "Hide \(name)" : "Show \(name)")
    }
}

/// A hidden part stays in place, faded and outlined, so it can be turned back on.
private struct MenuBarPartToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .opacity(configuration.isOn ? 1 : 0.35)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.white.opacity(configuration.isOn ? 0.18 : 0), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(configuration.isOn ? 0.25 : 0.45)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

private struct VercelPreferencesTab: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Authentication")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vercel API Token")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TokenField(text: $viewModel.vercelToken)
                            .help("Required. Create a token at vercel.com/account/tokens with 'Read Deployments' permission.")

                        if let tokenErrorMessage = viewModel.tokenErrorMessage {
                            Text("Couldn’t save token: \(tokenErrorMessage)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack {
                        Text("Scope & Project")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            viewModel.refreshRemoteOptions(forceReloadTeams: true)
                        }
                        .disabled(!viewModel.hasToken || viewModel.teamsLoading || viewModel.projectsLoading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Team Scopes")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $viewModel.teamSelectionMode) {
                                Text("All Accessible Scopes").tag(TeamSelectionMode.allAccessible)
                                Text("Choose Specific Scopes").tag(TeamSelectionMode.selected)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        if viewModel.teamsLoading {
                            ProgressView("Loading team scopes…")
                                .controlSize(.small)
                        } else if viewModel.teamSelectionMode == .selected {
                            if viewModel.availableTeamScopes.isEmpty {
                                Text("No scopes available for this token.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                CheckboxListBox {
                                    ForEach(viewModel.availableTeamScopes) { scope in
                                        Toggle(isOn: viewModel.teamSelectionBinding(for: scope.id)) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(scope.title)
                                                if let subtitle = scope.subtitle {
                                                    Text(subtitle)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Projects")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $viewModel.projectSelectionMode) {
                                Text("All Projects In Scope").tag(ProjectSelectionMode.allAccessible)
                                Text("Choose Specific Projects").tag(ProjectSelectionMode.selected)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        if viewModel.projectsLoading {
                            ProgressView("Loading projects…")
                                .controlSize(.small)
                        } else if viewModel.projectSelectionMode == .selected {
                            if viewModel.availableProjects.isEmpty {
                                Text("No projects found for the selected scope(s).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                CheckboxListBox {
                                    ForEach(viewModel.availableProjects) { project in
                                        Toggle(project.name, isOn: viewModel.projectSelectionBinding(for: project.name))
                                            .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                    }

                    if let optionsErrorMessage = viewModel.optionsErrorMessage {
                        Text("Couldn’t refresh scopes/projects: \(optionsErrorMessage)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Filters")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Git Branches (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("", text: $viewModel.gitBranches, prompt: Text("e.g. main, develop"))
                            .textFieldStyle(.roundedBorder)
                            .help("Comma-separated list of branches to filter (e.g. main, develop)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deployment Types")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Toggle("Production", isOn: $viewModel.showProduction)
                            Toggle("Preview", isOn: $viewModel.showPreview)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deployment States")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 16) {
                                Toggle("Ready", isOn: $viewModel.showReady)
                                Toggle("Building", isOn: $viewModel.showBuilding)
                            }
                            HStack(spacing: 16) {
                                Toggle("Error", isOn: $viewModel.showError)
                                Toggle("Queued", isOn: $viewModel.showQueued)
                            }
                            Toggle("Canceled", isOn: $viewModel.showCanceled)
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Limits")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Deployments (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $viewModel.limitByCount, placeholder: "e.g. 5")
                            .help("Maximum number of deployments to display (leave blank to ignore)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show Only Last X Hours (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $viewModel.limitByHours, placeholder: "e.g. 24")
                            .help("Only show deployments created within the last X hours (used when Maximum Deployments is empty)")
                    }

                    Text("Limit by count OR by time. If both are set, count takes priority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Refresh Intervals")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Idle Interval (seconds)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $viewModel.refreshIntervalIdle, placeholder: "Default: 15")
                            .help("How often to check for new deployments when none are building (in seconds)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Building Interval (seconds)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $viewModel.refreshIntervalBuilding, placeholder: "Default: 2")
                            .help("How often to check for updates when deployments are building or queued (in seconds)")
                    }

                    Text("Lower values provide faster updates but may use more API requests. Defaults: 15s idle, 2s building.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
    }
}

private struct CloudflarePreferencesTab: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @ObservedObject var filters: CloudflareFiltersModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Authentication")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cloudflare API Token")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TokenField(text: $viewModel.cloudflareToken)

                        if let tokenErrorMessage = viewModel.cloudflareTokenErrorMessage {
                            Text("Couldn’t save token: \(tokenErrorMessage)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack {
                        Text("Scope & Project")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            filters.refreshOptions()
                        }
                        .disabled(!filters.hasToken || filters.isLoading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Accounts")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $filters.accountSelectionMode) {
                                Text("All Accessible Accounts").tag(TeamSelectionMode.allAccessible)
                                Text("Choose Specific Accounts").tag(TeamSelectionMode.selected)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        if filters.isLoading {
                            ProgressView("Loading accounts…")
                                .controlSize(.small)
                        } else if filters.accountSelectionMode == .selected {
                            if filters.availableAccounts.isEmpty {
                                Text("No accounts available for this token.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                CheckboxListBox {
                                    ForEach(filters.availableAccounts) { account in
                                        Toggle(account.title, isOn: selectionBinding(account.id, in: \.selectedAccountIDs))
                                            .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Projects")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $filters.projectSelectionMode) {
                                Text("All Projects In Scope").tag(ProjectSelectionMode.allAccessible)
                                Text("Choose Specific Projects").tag(ProjectSelectionMode.selected)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        if filters.isLoading {
                            ProgressView("Loading projects…")
                                .controlSize(.small)
                        } else if filters.projectSelectionMode == .selected {
                            if filters.availableProjects.isEmpty {
                                Text("No projects found for the selected account(s).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                CheckboxListBox {
                                    ForEach(filters.availableProjects, id: \.self) { project in
                                        Toggle(isOn: selectionBinding(project, in: \.selectedProjects)) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(project.name)
                                                Text(projectSubtitle(project))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                    }

                    if let errorMessage = filters.errorMessage {
                        Text("Couldn’t refresh accounts/projects: \(errorMessage)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Filters")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Git Branches (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("", text: $filters.gitBranches, prompt: Text("e.g. main, develop"))
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deployment Types")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Toggle("Production", isOn: $filters.showProduction)
                            Toggle("Preview", isOn: $filters.showPreview)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deployment States")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 16) {
                                Toggle("Ready", isOn: $filters.showReady)
                                Toggle("Building", isOn: $filters.showBuilding)
                            }
                            HStack(spacing: 16) {
                                Toggle("Error", isOn: $filters.showError)
                                Toggle("Queued", isOn: $filters.showQueued)
                            }
                            HStack(spacing: 16) {
                                Toggle("Canceled", isOn: $filters.showCanceled)
                                Toggle("Skipped", isOn: $filters.showSkipped)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Limits")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Deployments (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $filters.limitByCount, placeholder: "e.g. 5")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show Only Last X Hours (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $filters.limitByHours, placeholder: "e.g. 24")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Refresh Intervals")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full Refresh Interval (seconds)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $viewModel.cloudflareRefreshInterval, placeholder: "Default: 30")
                            .help("How often to fetch every Cloudflare deployment (in seconds, at least 10)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("In-Progress Interval (seconds)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NumericTextField(text: $viewModel.cloudflareFastRefreshInterval, placeholder: "Default: 5")
                            .help("How often to re-check only queued or building deployments (in seconds, at least 2)")
                    }

                    Text("Cloudflare allows 1200 API requests per 5 minutes per user. Defaults: 30s full, 5s in progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
    }

    private func selectionBinding<Element: Hashable>(
        _ element: Element,
        in keyPath: ReferenceWritableKeyPath<CloudflareFiltersModel, Set<Element>>
    ) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath].contains(element) },
            set: { isSelected in
                if isSelected {
                    filters[keyPath: keyPath].insert(element)
                } else {
                    filters[keyPath: keyPath].remove(element)
                }
            }
        )
    }

    private func projectSubtitle(_ project: CloudflareProjectScope) -> String {
        let kind = project.kind == .pages ? "Pages" : "Workers"
        guard let account = filters.accountTitle(for: project.accountID) else { return kind }
        return "\(kind) · \(account)"
    }
}

/// Bordered box around a scope picker's checkbox list.
private struct CheckboxListBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Secure token entry with a Show/Hide toggle for checking what was pasted.
private struct TokenField: View {
    @Binding var text: String
    @State private var showToken = false

    var body: some View {
        HStack(spacing: 10) {
            if showToken {
                TextField("", text: $text, prompt: Text("Enter your token"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                PasteableSecureField(text: $text, placeholder: "Enter your token")
            }

            Button(showToken ? "Hide" : "Show") {
                showToken.toggle()
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct PasteableSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = PasteEnabledSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBezeled = true
        field.drawsBackground = true
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.isBordered = true
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: PasteableSecureField

        init(parent: PasteableSecureField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            parent.text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private final class PasteEnabledSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command),
           let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                return true
            case "v":
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct NumericTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .onChange(of: text) { newValue in
                let filtered = newValue.filter { $0.isNumber }
                if filtered != newValue {
                    text = filtered
                }
            }
    }
}
