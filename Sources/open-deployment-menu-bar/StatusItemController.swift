import AppKit
import Foundation

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let deploymentService = DeploymentService()
    private let cloudflareService = CloudflareService()

    private var refreshTimer: Timer?
    private var cloudflareRefreshTimer: Timer?
    private var cloudflareFastTimer: Timer?
    private var tickTimer: Timer?
    private var vercel = PlatformStatus()
    private var cloudflareEnabled = true
    private var cloudflarePolling = CloudflarePolling()
    private var cloudflareFastFetchInFlight = false
    private var cloudflareAccountIDs: [String] = []
    private var lastFetchDate: Date?

    private var cloudflare: PlatformStatus {
        cloudflareEnabled ? cloudflarePolling.status(at: Date()) : PlatformStatus(isEnabled: false)
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
            // Rebuild right away so a layout change shows without waiting for the refetch.
            self?.buildMenu()
            self?.refreshDeployments(userInitiated: true)
        }

        buildMenu()
        startTickTimer()
        refreshDeployments()
    }

    func stop() {
        preferencesObserver.flatMap(NotificationCenter.default.removeObserver)
        preferencesObserver = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        cloudflareRefreshTimer?.invalidate()
        cloudflareRefreshTimer = nil
        cloudflareFastTimer?.invalidate()
        cloudflareFastTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    @objc private func refreshFromMenu(_ sender: Any?) {
        refreshDeployments(userInitiated: true)
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
        if cloudflareAccountIDs.count == 1 {
            urlString += cloudflareAccountIDs[0]
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
        if cloudflareEnabled, cloudflarePolling.pausedUntil != nil {
            buildMenu()
        }
    }

    private func scheduleRefreshTimer(hasBuilding: Bool) {
        refreshTimer?.invalidate()
        let preferences = PreferencesStore.shared.current
        let idleInterval = TimeInterval(preferences.refreshIntervalIdle ?? 15)
        let buildingInterval = TimeInterval(preferences.refreshIntervalBuilding ?? 2)
        let interval: TimeInterval = hasBuilding ? buildingInterval : idleInterval
        refreshTimer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(triggerRefreshTimer),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    /// Applies the Cloudflare polling plan. The full-fetch timer restarts only when `restartingFullFetch` is set, so
    /// fast re-queries do not keep postponing it; the fast timer runs only while the plan has a fast interval.
    private func scheduleCloudflareTimers(restartingFullFetch: Bool) {
        let preferences = PreferencesStore.shared.current.cloudflare
        let plan = cloudflarePolling.plan(at: Date(), preferences: preferences)

        if restartingFullFetch {
            cloudflareRefreshTimer?.invalidate()
            let timer = Timer(
                fireAt: plan.nextFullFetch,
                interval: preferences.effectiveRefreshInterval,
                target: self,
                selector: #selector(triggerCloudflareRefreshTimer),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            cloudflareRefreshTimer = timer
        }

        guard let fastInterval = plan.fastInterval else {
            cloudflareFastTimer?.invalidate()
            cloudflareFastTimer = nil
            return
        }
        if let cloudflareFastTimer, cloudflareFastTimer.isValid, cloudflareFastTimer.timeInterval == fastInterval {
            return
        }
        cloudflareFastTimer?.invalidate()
        let timer = Timer(
            timeInterval: fastInterval,
            target: self,
            selector: #selector(triggerCloudflareFastTimer),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        cloudflareFastTimer = timer
    }

    @objc private func triggerRefreshTimer() {
        refreshVercel()
    }

    @objc private func triggerCloudflareRefreshTimer() {
        refreshCloudflare()
    }

    @objc private func triggerCloudflareFastTimer() {
        refreshCloudflareInProgress()
    }

    private func refreshDeployments(userInitiated: Bool = false) {
        refreshVercel()
        refreshCloudflare()
    }

    private func refreshVercel() {
        guard let token = PreferencesStore.shared.token(for: .vercel) else {
            vercel = PlatformStatus(isEnabled: false)
            render()
            return
        }
        Task {
            do {
                let preferences = PreferencesStore.shared.current
                let deployments = try await deploymentService.fetchAllDeployments(preferences: preferences, token: token)
                let filtered = filterDeployments(deployments, with: preferences)

                await MainActor.run {
                    // The token may have been removed or replaced while the request was in flight.
                    guard PreferencesStore.shared.token(for: .vercel) == token else { return }
                    self.vercel = PlatformStatus(deployments: filtered)
                    self.lastFetchDate = Date()
                    let hasBuilding = filtered.contains { $0.state == .building || $0.state == .queued }
                    self.scheduleRefreshTimer(hasBuilding: hasBuilding)
                    self.render()
                }
            } catch {
                await MainActor.run {
                    guard PreferencesStore.shared.token(for: .vercel) == token else { return }
                    self.vercel = PlatformStatus(issue: PlatformIssue(message: error.localizedDescription))
                    // Keep polling on the idle interval so a recovered platform clears its ⚠ on its own.
                    self.scheduleRefreshTimer(hasBuilding: false)
                    // The token may have been replaced outside the app (e.g. `security` CLI); re-read it next poll.
                    PreferencesStore.shared.discardCachedToken(for: .vercel)
                    self.render()
                }
            }
        }
    }

    /// Full fetch on its own interval, independent of Vercel's polling. During a 429 pause nothing is sent; the
    /// full-fetch timer fires again when the pause ends.
    private func refreshCloudflare() {
        guard let token = PreferencesStore.shared.token(for: .cloudflare) else {
            cloudflareRefreshTimer?.invalidate()
            cloudflareRefreshTimer = nil
            cloudflareFastTimer?.invalidate()
            cloudflareFastTimer = nil
            cloudflareEnabled = false
            cloudflarePolling = CloudflarePolling()
            cloudflareAccountIDs = []
            render()
            return
        }
        cloudflareEnabled = true
        scheduleCloudflareTimers(restartingFullFetch: true)
        guard !cloudflarePolling.isPaused(at: Date()) else {
            render()
            return
        }
        let preferences = PreferencesStore.shared.current.cloudflare
        Task {
            do {
                let snapshot = try await cloudflareService.fetchDeployments(token: token, preferences: preferences)
                let filtered = preferences.filter(snapshot.deployments)

                await MainActor.run {
                    guard PreferencesStore.shared.token(for: .cloudflare) == token else { return }
                    self.cloudflarePolling.applyFullFetch(
                        rows: filtered,
                        pendingItems: snapshot.pendingItems,
                        issue: snapshot.issue
                    )
                    self.cloudflareAccountIDs = snapshot.accountIDs
                    self.lastFetchDate = Date()
                    self.scheduleCloudflareTimers(restartingFullFetch: false)
                    self.render()
                }
            } catch {
                await MainActor.run {
                    guard PreferencesStore.shared.token(for: .cloudflare) == token else { return }
                    self.applyCloudflareFailure(error)
                }
            }
        }
    }

    /// Fast tier: re-queries only the in-progress rows of the last full fetch, one request each. When one finishes,
    /// a full fetch picks up the rows it joins with.
    private func refreshCloudflareInProgress() {
        let items = cloudflarePolling.pendingItems
        guard
            !cloudflareFastFetchInFlight,
            !items.isEmpty,
            !cloudflarePolling.isPaused(at: Date()),
            let token = PreferencesStore.shared.token(for: .cloudflare)
        else { return }
        cloudflareFastFetchInFlight = true
        Task {
            let result: Result<[CloudflarePendingUpdate], Error>
            do {
                result = .success(try await cloudflareService.fetchPendingUpdates(token: token, items: items))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.cloudflareFastFetchInFlight = false
                guard PreferencesStore.shared.token(for: .cloudflare) == token else { return }
                switch result {
                case let .success(updates):
                    let finished = self.cloudflarePolling.applyUpdates(updates)
                    self.render()
                    if finished {
                        self.refreshCloudflare()
                    } else {
                        self.scheduleCloudflareTimers(restartingFullFetch: false)
                    }
                case let .failure(error):
                    // Other failures are left to the next full fetch, which reports them.
                    guard CloudflareAPIError.rateLimitEnd(of: error) != nil else { return }
                    self.applyCloudflareFailure(error)
                }
            }
        }
    }

    private func applyCloudflareFailure(_ error: Error) {
        cloudflarePolling.applyFailure(error)
        if CloudflareAPIError.rateLimitEnd(of: error) == nil {
            // The token may have been replaced outside the app (e.g. `security` CLI); re-read it next poll.
            PreferencesStore.shared.discardCachedToken(for: .cloudflare)
        }
        // A pause moves the next full fetch to its end; otherwise keep polling on the full interval.
        scheduleCloudflareTimers(restartingFullFetch: cloudflarePolling.pausedUntil != nil)
        render()
    }

    private func render() {
        buildMenu()
        updateStatusButton()
    }

    private func filterDeployments(_ deployments: [Deployment], with preferences: Preferences) -> [Deployment] {
        let normalizedProjectNames = preferences.normalizedProjectNameSet

        var filtered = deployments.filter { deployment in
            if !normalizedProjectNames.isEmpty {
                let normalizedDeploymentName = deployment.projectName.lowercased()
                guard normalizedProjectNames.contains(normalizedDeploymentName) else { return false }
            }

            switch deployment.state {
            case .ready:
                guard preferences.showReady else { return false }
            case .building:
                guard preferences.showBuilding else { return false }
            case .error:
                guard preferences.showError else { return false }
            case .queued:
                guard preferences.showQueued else { return false }
            case .canceled:
                guard preferences.showCanceled else { return false }
            case .skipped, .unknown:
                break
            }

            switch deployment.environment {
            case .production:
                guard preferences.showProduction else { return false }
            case .preview:
                guard preferences.showPreview else { return false }
            case .custom, nil:
                break
            }

            if !preferences.branchList.isEmpty {
                let branch = (deployment.branch ?? "").lowercased()
                if branch.isEmpty || !preferences.branchList.contains(branch) {
                    return false
                }
            }

            return true
        }

        if let limit = preferences.limitByCount, limit > 0 {
            filtered = Array(filtered.prefix(limit))
        } else if let hours = preferences.limitByHours, hours > 0 {
            let cutoff = Date().addingTimeInterval(TimeInterval(-hours * 3600))
            filtered = filtered.filter { $0.createdAt >= cutoff }
        }

        return filtered.sorted { $0.createdAt > $1.createdAt }
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
            // The menu bar keeps both platform symbols in the label color; menu rows use brand colors.
            button.image = icon(for: latest, brandColored: false)
            let title = formattedStatusTitle(for: latest)
            button.title = warning ? "\(title) ⚠" : title
        }
    }

    private func formattedStatusTitle(for deployment: Deployment) -> String {
        let label = String(deployment.projectName.prefix(3)).uppercased()
        switch deployment.state {
        case .building:
            let elapsed = Date().timeIntervalSince(deployment.buildStartDate)
            return "\(label) \(formatDuration(elapsed))"
        case .queued:
            let elapsed = Date().timeIntervalSince(deployment.createdAt)
            return "\(label) \(formatDuration(elapsed))"
        case .ready:
            if let finishedAt = deployment.finishedAt {
                let elapsed = finishedAt.timeIntervalSince(deployment.buildStartDate)
                return "\(label) \(formatDuration(max(elapsed, 0)))"
            }
            return label
        case .error:
            if let finishedAt = deployment.finishedAt {
                let elapsed = finishedAt.timeIntervalSince(deployment.buildStartDate)
                let formatted = formatDuration(max(elapsed, 0))
                return "\(label) \(formatted)"
            }
            return label
        case .canceled, .skipped, .unknown:
            return label
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let sec = Int(seconds)
        let hours = sec / 3600
        let minutes = (sec % 3600) / 60
        let remaining = sec % 60

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

        if let lastFetchDate {
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
