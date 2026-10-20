import AppKit
import Foundation

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let poller = DeploymentPoller()
    private var tickTimer: Timer?

    private var vercel: PlatformStatus {
        poller.vercel
    }

    private var cloudflare: PlatformStatus {
        poller.cloudflare
    }

    private var statusButtonState: StatusButtonState {
        StatusButtonState(platforms: [vercel, cloudflare])
    }

    private var preferencesObserver: NSObjectProtocol?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        updateStatusButton()
    }

    func start() {
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: PreferencesStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Rebuild right away so a layout or menu bar change shows without waiting for the refetch.
            self?.buildMenu()
            self?.updateStatusButton()
            self?.poller.refresh()
        }
        poller.onUpdate = { [weak self] in self?.render() }

        buildMenu()
        startTickTimer()
        poller.refresh()
    }

    func stop() {
        preferencesObserver.flatMap(NotificationCenter.default.removeObserver)
        preferencesObserver = nil
        poller.stop()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    @objc private func refreshFromMenu(_ sender: Any?) {
        poller.refresh()
    }

    @objc private func openDashboard(_ sender: Any?) {
        let preferences = PreferencesStore.shared.current
        var urlString = "https://vercel.com/deployments"
        let teamIds = preferences.teamIdList
        if
            teamIds.count == 1,
            teamIds[0] != Preferences.personalScopeIdentifier
        {
            urlString = "https://vercel.com/\(teamIds[0])/deployments"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openCloudflareDashboard(_ sender: Any?) {
        var urlString = "https://dash.cloudflare.com/"
        if poller.cloudflareAccountIDs.count == 1 {
            urlString += poller.cloudflareAccountIDs[0]
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDeployment(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.show()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    @objc private func tick() {
        updateStatusButton()
        // The rate-limit banner counts down, so rebuild the menu while paused.
        if poller.cloudflarePausedUntil != nil {
            buildMenu()
        }
    }

    private func render() {
        buildMenu()
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        switch statusButtonState {
        case .noToken:
            button.title = "No Token"
            button.image = NSImage(systemSymbolName: "key.slash", accessibilityDescription: nil)
        case .error:
            button.title = "Error"
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        case let .empty(warning):
            button.title = warning ? "⚠" : ""
            button.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        case let .deployment(latest, warning):
            let display = PreferencesStore.shared.current.general.menuBar
            let title = formattedStatusTitle(for: latest, display: display)
            // When only the build time is shown and this deployment has none, show its state rather than vanish.
            button.image = statusImage(for: latest, display: display) ?? (title.isEmpty ? icon(for: latest.state) : nil)
            button.title = warning ? (title.isEmpty ? "⚠" : "\(title) ⚠") : title
        }
    }

    /// The menu bar keeps platform symbols in the label color; menu rows use brand colors.
    private func statusImage(for deployment: Deployment, display: MenuBarDisplay) -> NSImage? {
        switch (display.showsPlatformIcon, display.showsStatusIcon) {
        case (true, true):
            return icon(for: deployment, brandColored: false)
        case (true, false):
            return NSImage(systemSymbolName: platformSymbolName(for: deployment.platform), accessibilityDescription: nil)
        case (false, true):
            return icon(for: deployment.state)
        case (false, false):
            return nil
        }
    }

    private func formattedStatusTitle(for deployment: Deployment, display: MenuBarDisplay) -> String {
        var parts: [String] = []
        if display.showsProjectName {
            parts.append(display.projectLabel(for: deployment.projectName))
        }
        if display.showsBuildTime, let elapsed = buildTime(of: deployment) {
            parts.append(formatDuration(elapsed, style: display.buildTimeStyle))
        }
        return parts.joined(separator: " ")
    }

    /// Time spent so far while building or queued, the final build time once finished, otherwise nil.
    private func buildTime(of deployment: Deployment) -> TimeInterval? {
        switch deployment.state {
        case .building:
            return Date().timeIntervalSince(deployment.buildStartDate)
        case .queued:
            return Date().timeIntervalSince(deployment.createdAt)
        case .ready, .error:
            return deployment.finishedAt.map { max($0.timeIntervalSince(deployment.buildStartDate), 0) }
        case .canceled, .skipped, .unknown:
            return nil
        }
    }

    private func formatDuration(_ seconds: TimeInterval, style: BuildTimeStyle = .full) -> String {
        let sec = Int(seconds)
        let hours = sec / 3600
        let minutes = (sec % 3600) / 60
        let remaining = sec % 60

        if style == .compact {
            return hours > 0 ? "\(hours)h" : minutes > 0 ? "\(minutes)m" : "\(remaining)s"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m \(remaining)s"
        } else if minutes > 0 {
            return "\(minutes)m \(remaining)s"
        } else {
            return "\(remaining)s"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Platform symbol followed by the colored state symbol, composited so a single `NSImage` slot
    /// (status button or menu item) can show both. With `brandColored`, Cloudflare is drawn in Cloudflare
    /// orange; otherwise every platform symbol uses the label color.
    private func icon(for deployment: Deployment, brandColored: Bool) -> NSImage? {
        guard
            let platformSymbol = NSImage(
                systemSymbolName: platformSymbolName(for: deployment.platform),
                accessibilityDescription: nil
            ),
            let stateImage = icon(for: deployment.state)
        else {
            return icon(for: deployment.state)
        }

        let spacing: CGFloat = 3
        let platformColor = brandColored ? platformTint(for: deployment.platform) : .labelColor
        let platformSize = platformSymbol.size
        let stateSize = stateImage.size
        let size = NSSize(
            width: platformSize.width + spacing + stateSize.width,
            height: max(platformSize.height, stateSize.height)
        )

        let image = NSImage(size: size, flipped: false) { _ in
            let platformRect = NSRect(
                x: 0,
                y: (size.height - platformSize.height) / 2,
                width: platformSize.width,
                height: platformSize.height
            )
            platformSymbol.draw(in: platformRect)
            // Dynamic colors such as labelColor resolve when set inside the handler (draw time), so the
            // symbol follows the menu bar or menu appearance like a template image would.
            platformColor.set()
            platformRect.fill(using: .sourceAtop)

            let stateRect = NSRect(
                x: platformRect.maxX + spacing,
                y: (size.height - stateSize.height) / 2,
                width: stateSize.width,
                height: stateSize.height
            )
            stateImage.draw(in: stateRect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func platformSymbolName(for platform: Deployment.Platform) -> String {
        switch platform {
        case .vercel:
            return "triangle.fill"
        case .cloudflarePages, .cloudflareWorkers:
            return "cloud.fill"
        }
    }

    private func platformTint(for platform: Deployment.Platform) -> NSColor {
        switch platform {
        case .vercel:
            return .labelColor
        case .cloudflarePages, .cloudflareWorkers:
            // Cloudflare brand orange (#F38020).
            return NSColor(srgbRed: 0xF3 / 255, green: 0x80 / 255, blue: 0x20 / 255, alpha: 1)
        }
    }

    private func platformLabel(for platform: Deployment.Platform) -> String? {
        switch platform {
        case .vercel:
            return nil
        case .cloudflarePages:
            return "Pages"
        case .cloudflareWorkers:
            return "Workers"
        }
    }

    private func icon(for state: Deployment.State) -> NSImage? {
        let symbolName: String
        let color: NSColor

        switch state {
        case .ready:
            symbolName = "checkmark.circle.fill"
            color = .systemGreen
        case .error:
            symbolName = "xmark.circle.fill"
            color = .systemRed
        case .building:
            symbolName = "hourglass"
            color = .systemYellow
        case .queued:
            symbolName = "clock.fill"
            color = .systemOrange
        case .canceled:
            symbolName = "minus.circle.fill"
            color = .systemGray
        case .skipped:
            symbolName = "forward.end.circle.fill"
            color = .systemGray
        case .unknown:
            symbolName = "questionmark.circle"
            color = .systemGray
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }

        // Create a colored version of the image
        let coloredImage = NSImage(size: image.size)
        coloredImage.lockFocus()
        color.set()

        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1.0)

        // Apply the color using a compositing operation
        rect.fill(using: .sourceAtop)

        coloredImage.unlockFocus()
        coloredImage.isTemplate = false

        return coloredImage
    }

    private func buildMenu() {
        menu.removeAllItems()

        let composition = MenuComposition(
            layout: PreferencesStore.shared.current.general.menuLayout,
            vercel: vercel,
            cloudflare: cloudflare
        )
        for entry in composition.entries {
            menu.addItem(menuItem(for: entry))
        }

        if let lastFetchDate = poller.lastFetchDate {
            menu.addItem(.separator())
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let updatedTitle = "Last updated: \(formatter.string(from: lastFetchDate))"
            let updatedItem = NSMenuItem(title: updatedTitle, action: nil, keyEquivalent: "")
            updatedItem.isEnabled = false
            menu.addItem(updatedItem)
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshFromMenu(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        for platform in composition.footerDashboards {
            menu.addItem(dashboardItem(for: platform))
        }

        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Open Deployment Menu Bar", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func menuItem(for entry: MenuEntry) -> NSMenuItem {
        switch entry {
        case let .notice(text):
            return NSMenuItem(title: text, action: nil, keyEquivalent: "")
        case let .banner(text):
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            item.keepsImageVisible()
            return item
        case let .header(title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case let .deployment(deployment):
            let item = NSMenuItem(
                title: menuTitle(for: deployment),
                action: #selector(openDeployment(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = deployment.openURL
            item.toolTip = commitToolTip(for: deployment)
            item.image = icon(for: deployment, brandColored: true)
            item.keepsImageVisible()
            return item
        case let .dashboard(platform):
            return dashboardItem(for: platform)
        case .separator:
            return .separator()
        }
    }

    private func dashboardItem(for platform: MenuPlatform) -> NSMenuItem {
        let action = platform == .vercel
            ? #selector(openDashboard(_:))
            : #selector(openCloudflareDashboard(_:))
        let item = NSMenuItem(title: "Open \(platform.name) Dashboard", action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func menuTitle(for deployment: Deployment) -> String {
        var components: [String] = []

        if let branch = deployment.branch {
            components.append("\(deployment.projectName) (\(branch))")
        } else {
            components.append(deployment.projectName)
        }

        var statusParts: [String] = []
        if let platformLabel = platformLabel(for: deployment.platform) {
            statusParts.append(platformLabel)
        }
        if let sourceLabel = deployment.sourceLabel {
            statusParts.append(sourceLabel)
        }
        if let trafficPercentage = deployment.trafficPercentage {
            statusParts.append("\(trafficPercentage)%")
        }

        // Workers deployments are always production, so the environment would add nothing.
        if deployment.platform != .cloudflareWorkers {
            switch deployment.environment {
            case .production:
                statusParts.append("Production")
            case .preview:
                statusParts.append("Preview")
            case let .custom(name):
                statusParts.append(name.capitalized)
            case nil:
                break
            }
        }

        switch deployment.state {
        case .building:
            statusParts.append("Building \(formatDuration(Date().timeIntervalSince(deployment.buildStartDate)))")
        case .queued:
            statusParts.append("Queued \(formatDuration(Date().timeIntervalSince(deployment.createdAt)))")
        case .ready:
            if let finishedAt = deployment.finishedAt {
                let duration = finishedAt.timeIntervalSince(deployment.buildStartDate)
                statusParts.append("Ready \(formatDuration(max(duration, 0)))")
            } else {
                statusParts.append("Ready")
            }
        case .error:
            statusParts.append("Error")
        case .canceled:
            statusParts.append("Canceled")
        case .skipped:
            statusParts.append("Skipped")
        case .unknown:
            statusParts.append("Unknown")
        }

        let timeString = formatTime(deployment.buildStartDate)
        statusParts.append(timeString)

        if !statusParts.isEmpty {
            components.append(statusParts.joined(separator: " • "))
        }

        return components.joined(separator: " — ")
    }

    private func commitToolTip(for deployment: Deployment) -> String? {
        Self.sanitizedCommitToolTip(from: deployment.commitMessage)
    }

    static func sanitizedCommitToolTip(from rawMessage: String?) -> String? {
        guard let rawMessage else {
            return nil
        }

        let firstLine = rawMessage
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else {
            return nil
        }

        let collapsed = firstLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return nil
        }

        let maxLength = 90
        guard collapsed.count > maxLength else {
            return collapsed
        }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxLength - 1)
        return String(collapsed[..<cutoff]) + "…"
    }
}

private extension NSMenuItem {
    /// Apps linked against the macOS 27 SDK get menu item images hidden by default. These images carry the
    /// platform and state of a row (or the ⚠ of a banner), so they stay visible.
    func keepsImageVisible() {
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }
}
