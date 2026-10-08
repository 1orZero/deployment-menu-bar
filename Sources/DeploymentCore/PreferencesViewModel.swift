import Combine
import Foundation
import SwiftUI

enum TeamSelectionMode: String, CaseIterable, Identifiable {
    case allAccessible
    case selected

    var id: String { rawValue }
}

enum ProjectSelectionMode: String, CaseIterable, Identifiable {
    case allAccessible
    case selected

    var id: String { rawValue }
}

struct TeamScopeOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?

    static let personal = TeamScopeOption(
        id: Preferences.personalScopeIdentifier,
        title: "Personal Account",
        subtitle: "Deployments under your personal scope"
    )
}

struct ProjectFilterOption: Identifiable, Hashable {
    let id: String
    let name: String
}

final class PreferencesLookupService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchTeams(token: String) async throws -> [Team] {
        guard let url = URL(string: "https://api.vercel.com/v2/teams") else {
            return []
        }

        let data = try await requestData(url: url, token: token)
        guard let decoded = try? JSONDecoder().decode(TeamsResponse.self, from: data) else {
            throw APIError.decodingFailure
        }
        return decoded.teams
    }

    func fetchProjects(token: String, teamId: String?) async throws -> [Project] {
        var components = URLComponents(string: "https://api.vercel.com/v9/projects")!
        var queryItems = [URLQueryItem(name: "limit", value: "100")]
        if let teamId, !teamId.isEmpty {
            queryItems.append(URLQueryItem(name: "teamId", value: teamId))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            return []
        }

        let data = try await requestData(url: url, token: token)
        guard let decoded = try? JSONDecoder().decode(ProjectsResponse.self, from: data) else {
            throw APIError.decodingFailure
        }
        return decoded.projects
    }

    private func requestData(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse(status: -1, message: "No response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.invalidResponse(status: httpResponse.statusCode, message: message)
        }

        return data
    }
}

final class PreferencesViewModel: ObservableObject {
    @Published var menuLayout: MenuLayout
    @Published var vercelToken: String
    @Published var cloudflareToken: String
    @Published var gitBranches: String
    @Published var showProduction: Bool
    @Published var showPreview: Bool
    @Published var showReady: Bool
    @Published var showBuilding: Bool
    @Published var showError: Bool
    @Published var showQueued: Bool
    @Published var showCanceled: Bool
    @Published var limitByCount: String
    @Published var limitByHours: String
    @Published var refreshIntervalIdle: String
    @Published var refreshIntervalBuilding: String
    @Published var cloudflareRefreshInterval: String
    @Published var cloudflareFastRefreshInterval: String

    @Published var teamSelectionMode: TeamSelectionMode
    @Published var selectedTeamScopeIDs: Set<String>
    @Published var projectSelectionMode: ProjectSelectionMode
    @Published var selectedProjectNames: Set<String>

    @Published private(set) var availableTeamScopes: [TeamScopeOption]
    @Published private(set) var availableProjects: [ProjectFilterOption]
    @Published private(set) var teamsLoading: Bool
    @Published private(set) var projectsLoading: Bool
    @Published private(set) var optionsErrorMessage: String?
    @Published private(set) var tokenErrorMessage: String?
    @Published private(set) var cloudflareTokenErrorMessage: String?

    private let store: PreferencesStore
    private let lookupService: PreferencesLookupService
    let cloudflareFilters: CloudflareFiltersModel

    private var cancellables: Set<AnyCancellable> = []
    private var lookupTask: Task<Void, Never>?
    private var isHydrating = false

    init(
        store: PreferencesStore,
        lookupService: PreferencesLookupService = PreferencesLookupService()
    ) {
        self.store = store
        self.lookupService = lookupService
        cloudflareFilters = CloudflareFiltersModel(store: store)

        let current = store.current

        menuLayout = current.general.menuLayout
        vercelToken = store.token(for: .vercel) ?? ""
        cloudflareToken = store.token(for: .cloudflare) ?? ""
        gitBranches = current.gitBranches
        showProduction = current.showProduction
        showPreview = current.showPreview
        showReady = current.showReady
        showBuilding = current.showBuilding
        showError = current.showError
        showQueued = current.showQueued
        showCanceled = current.showCanceled
        limitByCount = current.limitByCount.map(String.init) ?? ""
        limitByHours = current.limitByHours.map(String.init) ?? ""
        refreshIntervalIdle = current.refreshIntervalIdle.map(String.init) ?? ""
        refreshIntervalBuilding = current.refreshIntervalBuilding.map(String.init) ?? ""
        cloudflareRefreshInterval = String(current.cloudflare.refreshInterval)
        cloudflareFastRefreshInterval = String(current.cloudflare.fastRefreshInterval)

        let teamIds = current.teamIdList
        teamSelectionMode = teamIds.isEmpty ? .allAccessible : .selected
        selectedTeamScopeIDs = Set(teamIds)

        let projectNames = current.projectNameList
        projectSelectionMode = projectNames.isEmpty ? .allAccessible : .selected
        selectedProjectNames = Set(projectNames)

        availableTeamScopes = [.personal]
        availableProjects = []
        teamsLoading = false
        projectsLoading = false
        optionsErrorMessage = nil

        setupObservers()
        refreshRemoteOptions(forceReloadTeams: true)
    }

    var hasToken: Bool {
        !vercelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        hydrate(from: store.current)
        refreshRemoteOptions(forceReloadTeams: true)
        cloudflareFilters.hydrate()
        cloudflareFilters.refreshOptions()
    }

    func saveAndClose() {
        persistPreferences()
    }

    func refreshRemoteOptions(forceReloadTeams: Bool = true) {
        guard !isHydrating else { return }

        let token = vercelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            availableTeamScopes = [.personal]
            availableProjects = []
            teamsLoading = false
            projectsLoading = false
            optionsErrorMessage = nil
            return
        }

        lookupTask?.cancel()
        lookupTask = Task { [weak self] in
            guard let self else { return }
            await self.loadRemoteOptions(token: token, forceReloadTeams: forceReloadTeams)
        }
    }

    func teamSelectionBinding(for scopeId: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedTeamScopeIDs.contains(scopeId) },
            set: { isSelected in
                var updated = self.selectedTeamScopeIDs
                if isSelected {
                    updated.insert(scopeId)
                } else {
                    updated.remove(scopeId)
                }
                self.selectedTeamScopeIDs = updated
                self.persistPreferences()
            }
        )
    }

    func projectSelectionBinding(for projectName: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedProjectNames.contains(projectName) },
            set: { isSelected in
                var updated = self.selectedProjectNames
                if isSelected {
                    updated.insert(projectName)
                } else {
                    updated.remove(projectName)
                }
                self.selectedProjectNames = updated
                self.persistPreferences()
            }
        )
    }

    private func hydrate(from current: Preferences) {
        isHydrating = true

        menuLayout = current.general.menuLayout
        vercelToken = store.token(for: .vercel) ?? ""
        cloudflareToken = store.token(for: .cloudflare) ?? ""
        gitBranches = current.gitBranches
        showProduction = current.showProduction
        showPreview = current.showPreview
        showReady = current.showReady
        showBuilding = current.showBuilding
        showError = current.showError
        showQueued = current.showQueued
        showCanceled = current.showCanceled
        limitByCount = current.limitByCount.map(String.init) ?? ""
        limitByHours = current.limitByHours.map(String.init) ?? ""
        refreshIntervalIdle = current.refreshIntervalIdle.map(String.init) ?? ""
        refreshIntervalBuilding = current.refreshIntervalBuilding.map(String.init) ?? ""
        cloudflareRefreshInterval = String(current.cloudflare.refreshInterval)
        cloudflareFastRefreshInterval = String(current.cloudflare.fastRefreshInterval)

        let teamIds = current.teamIdList
        teamSelectionMode = teamIds.isEmpty ? .allAccessible : .selected
        selectedTeamScopeIDs = Set(teamIds)

        let projectNames = current.projectNameList
        projectSelectionMode = projectNames.isEmpty ? .allAccessible : .selected
        selectedProjectNames = Set(projectNames)

        isHydrating = false
    }

    private func setupObservers() {
        $vercelToken
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] token in
                guard let self, !self.isHydrating else { return }
                self.tokenErrorMessage = self.saveToken(token, for: .vercel)
            }
            .store(in: &cancellables)

        $cloudflareToken
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] token in
                guard let self, !self.isHydrating else { return }
                self.cloudflareTokenErrorMessage = self.saveToken(token, for: .cloudflare)
            }
            .store(in: &cancellables)

        // `@Published` emits before the property changes, so save the emitted value rather than re-reading it.
        $menuLayout
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] layout in
                guard let self, !self.isHydrating else { return }
                self.store.update { $0.general.menuLayout = layout }
            }
            .store(in: &cancellables)

        $cloudflareRefreshInterval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] text in
                guard let self, !self.isHydrating else { return }
                self.store.update {
                    $0.cloudflare.refreshInterval = Self.cloudflareInterval(
                        from: text,
                        default: CloudflarePreferences.default.refreshInterval,
                        minimum: CloudflarePreferences.minimumRefreshInterval
                    )
                }
            }
            .store(in: &cancellables)

        $cloudflareFastRefreshInterval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] text in
                guard let self, !self.isHydrating else { return }
                self.store.update {
                    $0.cloudflare.fastRefreshInterval = Self.cloudflareInterval(
                        from: text,
                        default: CloudflarePreferences.default.fastRefreshInterval,
                        minimum: CloudflarePreferences.minimumFastRefreshInterval
                    )
                }
            }
            .store(in: &cancellables)

        observeAutoSave($gitBranches)
        observeAutoSave($showProduction)
        observeAutoSave($showPreview)
        observeAutoSave($showReady)
        observeAutoSave($showBuilding)
        observeAutoSave($showError)
        observeAutoSave($showQueued)
        observeAutoSave($showCanceled)
        observeAutoSave($limitByCount)
        observeAutoSave($limitByHours)
        observeAutoSave($refreshIntervalIdle)
        observeAutoSave($refreshIntervalBuilding)
        observeAutoSave($teamSelectionMode)
        observeAutoSave($selectedTeamScopeIDs)
        observeAutoSave($projectSelectionMode)
        observeAutoSave($selectedProjectNames)

        $vercelToken
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshRemoteOptions(forceReloadTeams: true)
            }
            .store(in: &cancellables)

        $cloudflareToken
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cloudflareFilters.refreshOptions()
            }
            .store(in: &cancellables)

        Publishers.Merge(
            $teamSelectionMode.dropFirst().map { _ in () },
            $selectedTeamScopeIDs.dropFirst().map { _ in () }
        )
        .sink { [weak self] _ in
            self?.refreshRemoteOptions(forceReloadTeams: false)
        }
        .store(in: &cancellables)
    }

    /// Saves the token and returns the error message to show, if any.
    private func saveToken(_ token: String, for account: TokenAccount) -> String? {
        do {
            try store.setToken(token, for: account)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func observeAutoSave<T>(_ publisher: Published<T>.Publisher) {
        publisher
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistPreferences()
            }
            .store(in: &cancellables)
    }

    private func persistPreferences() {
        guard !isHydrating else { return }

        store.update { preferences in
            preferences.teamId = serializedTeamScopeIDs
            preferences.projectName = serializedProjectNames
            preferences.gitBranches = gitBranches
            preferences.showProduction = showProduction
            preferences.showPreview = showPreview
            preferences.showReady = showReady
            preferences.showBuilding = showBuilding
            preferences.showError = showError
            preferences.showQueued = showQueued
            preferences.showCanceled = showCanceled
            preferences.limitByCount = Int(limitByCount)
            preferences.limitByHours = Int(limitByHours)
            preferences.refreshIntervalIdle = Int(refreshIntervalIdle)
            preferences.refreshIntervalBuilding = Int(refreshIntervalBuilding)
        }
    }

    /// Empty or invalid text keeps the default; values below the minimum are raised to it.
    private static func cloudflareInterval(from text: String, default defaultValue: Int, minimum: Int) -> Int {
        Int(text).map { max($0, minimum) } ?? defaultValue
    }

    private var serializedTeamScopeIDs: String {
        guard teamSelectionMode == .selected else { return "" }
        guard !selectedTeamScopeIDs.isEmpty else { return "" }
        return selectedTeamScopeIDs.sorted().joined(separator: ",")
    }

    private var serializedProjectNames: String {
        guard projectSelectionMode == .selected else { return "" }
        guard !selectedProjectNames.isEmpty else { return "" }
        return selectedProjectNames.sorted().joined(separator: ",")
    }

    private func loadRemoteOptions(token: String, forceReloadTeams: Bool) async {
        if forceReloadTeams {
            await MainActor.run {
                teamsLoading = true
                optionsErrorMessage = nil
            }

            do {
                let teams = try await lookupService.fetchTeams(token: token)
                let teamOptions = [TeamScopeOption.personal] + teams
                    .map { TeamScopeOption(id: $0.slug, title: $0.name, subtitle: $0.slug) }
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

                await MainActor.run {
                    availableTeamScopes = teamOptions
                    selectedTeamScopeIDs = selectedTeamScopeIDs.intersection(Set(teamOptions.map(\.id)))
                }
            } catch {
                if !shouldIgnoreLookupError(error) {
                    await MainActor.run {
                        availableTeamScopes = [.personal]
                        optionsErrorMessage = error.localizedDescription
                    }
                }
            }

            await MainActor.run {
                teamsLoading = false
            }
        }

        await MainActor.run {
            projectsLoading = true
        }

        do {
            let projects = try await fetchProjectsForCurrentScope(token: token)
            let options = deduplicateProjects(projects).map {
                ProjectFilterOption(id: $0, name: $0)
            }

            await MainActor.run {
                availableProjects = options
                selectedProjectNames = selectedProjectNames.intersection(Set(options.map(\.name)))
                optionsErrorMessage = nil
            }
        } catch {
            if !shouldIgnoreLookupError(error) {
                await MainActor.run {
                    availableProjects = []
                    optionsErrorMessage = error.localizedDescription
                }
            }
        }

        await MainActor.run {
            projectsLoading = false
        }
    }

    private func fetchProjectsForCurrentScope(token: String) async throws -> [Project] {
        if teamSelectionMode == .allAccessible {
            return try await lookupService.fetchProjects(token: token, teamId: nil)
        }

        let scopeIds = selectedTeamScopeIDs
        guard !scopeIds.isEmpty else { return [] }

        let outcome = await withTaskGroup(
            of: Result<[Project], Error>.self,
            returning: (projects: [Project], successCount: Int, firstError: Error?).self
        ) { group in
            for scopeId in scopeIds {
                group.addTask {
                    do {
                        let teamId: String? = (scopeId == Preferences.personalScopeIdentifier) ? nil : scopeId
                        let projects = try await self.lookupService.fetchProjects(token: token, teamId: teamId)
                        return .success(projects)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var all: [Project] = []
            var successCount = 0
            var firstError: Error?

            for await result in group {
                switch result {
                case let .success(projects):
                    successCount += 1
                    all.append(contentsOf: projects)
                case let .failure(error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            return (all, successCount, firstError)
        }

        if outcome.successCount == 0, let firstError = outcome.firstError {
            throw firstError
        }

        return outcome.projects
    }

    private func deduplicateProjects(_ projects: [Project]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []

        for project in projects {
            let key = project.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(project.name)
        }

        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func shouldIgnoreLookupError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

