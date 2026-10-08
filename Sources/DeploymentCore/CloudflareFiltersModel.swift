import Combine
import Foundation

/// Cloudflare tab state for the account/project scope, filters and limits; changes auto-save like the Vercel tab.
final class CloudflareFiltersModel: ObservableObject {
    struct AccountOption: Identifiable, Hashable {
        let id: String
        let title: String
    }

    @Published var accountSelectionMode: TeamSelectionMode = .allAccessible
    @Published var selectedAccountIDs: Set<String> = []
    @Published var projectSelectionMode: ProjectSelectionMode = .allAccessible
    @Published var selectedProjects: Set<CloudflareProjectScope> = []
    @Published var gitBranches = ""
    @Published var showProduction = true
    @Published var showPreview = true
    @Published var showReady = true
    @Published var showBuilding = true
    @Published var showError = true
    @Published var showQueued = true
    @Published var showCanceled = true
    @Published var showSkipped = true
    @Published var limitByCount = ""
    @Published var limitByHours = ""

    @Published private(set) var availableAccounts: [AccountOption] = []
    @Published private(set) var allProjects: [CloudflareProjectScope] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let store: PreferencesStore
    private let service: CloudflareService
    private var cancellables: Set<AnyCancellable> = []
    private var lookupTask: Task<Void, Never>?
    private var isHydrating = false

    init(store: PreferencesStore, service: CloudflareService = CloudflareService()) {
        self.store = store
        self.service = service
        hydrate()
        for publisher in [
            $accountSelectionMode.map { _ in () }.eraseToAnyPublisher(),
            $selectedAccountIDs.map { _ in () }.eraseToAnyPublisher(),
            $projectSelectionMode.map { _ in () }.eraseToAnyPublisher(),
            $selectedProjects.map { _ in () }.eraseToAnyPublisher(),
            $gitBranches.map { _ in () }.eraseToAnyPublisher(),
            $showProduction.map { _ in () }.eraseToAnyPublisher(),
            $showPreview.map { _ in () }.eraseToAnyPublisher(),
            $showReady.map { _ in () }.eraseToAnyPublisher(),
            $showBuilding.map { _ in () }.eraseToAnyPublisher(),
            $showError.map { _ in () }.eraseToAnyPublisher(),
            $showQueued.map { _ in () }.eraseToAnyPublisher(),
            $showCanceled.map { _ in () }.eraseToAnyPublisher(),
            $showSkipped.map { _ in () }.eraseToAnyPublisher(),
            $limitByCount.map { _ in () }.eraseToAnyPublisher(),
            $limitByHours.map { _ in () }.eraseToAnyPublisher(),
        ] {
            // `@Published` emits before the property changes; persist once the change has landed.
            publisher.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.persist() }
                .store(in: &cancellables)
        }
        refreshOptions()
    }

    var hasToken: Bool {
        store.token(for: .cloudflare) != nil
    }

    /// Projects offered in the picker: those of the selected accounts, or of every account.
    var availableProjects: [CloudflareProjectScope] {
        guard accountSelectionMode == .selected else { return allProjects }
        return allProjects.filter { selectedAccountIDs.contains($0.accountID) }
    }

    func accountTitle(for accountID: String) -> String? {
        guard availableAccounts.count > 1 else { return nil }
        return availableAccounts.first { $0.id == accountID }?.title
    }

    func hydrate() {
        isHydrating = true
        defer { isHydrating = false }
        let current = store.current.cloudflare
        accountSelectionMode = current.accountIDs.isEmpty ? .allAccessible : .selected
        selectedAccountIDs = Set(current.accountIDs)
        projectSelectionMode = current.projects.isEmpty ? .allAccessible : .selected
        selectedProjects = Set(current.projects)
        gitBranches = current.gitBranches
        showProduction = current.showProduction
        showPreview = current.showPreview
        showReady = current.showReady
        showBuilding = current.showBuilding
        showError = current.showError
        showQueued = current.showQueued
        showCanceled = current.showCanceled
        showSkipped = current.showSkipped
        limitByCount = current.limitByCount > 0 ? String(current.limitByCount) : ""
        limitByHours = current.limitByHours.map(String.init) ?? ""
    }

    func refreshOptions() {
        lookupTask?.cancel()
        guard let token = store.token(for: .cloudflare) else {
            availableAccounts = []
            allProjects = []
            isLoading = false
            errorMessage = nil
            return
        }
        isLoading = true
        lookupTask = Task { [weak self, service] in
            let result: Result<CloudflareScopeOptions, Error>
            do {
                result = .success(try await service.fetchScopeOptions(token: token))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            await self?.apply(result)
        }
    }

    @MainActor
    private func apply(_ result: Result<CloudflareScopeOptions, Error>) {
        isLoading = false
        switch result {
        case let .success(options):
            availableAccounts = options.accounts
                .map { AccountOption(id: $0.id, title: $0.name ?? $0.id) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            allProjects = options.projects.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            selectedAccountIDs.formIntersection(availableAccounts.map(\.id))
            selectedProjects.formIntersection(allProjects)
            errorMessage = nil
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func persist() {
        guard !isHydrating else { return }
        let accountIDs = accountSelectionMode == .selected ? selectedAccountIDs.sorted() : []
        let projects = projectSelectionMode == .selected
            ? selectedProjects.sorted { ($0.accountID, $0.kind.rawValue, $0.name) < ($1.accountID, $1.kind.rawValue, $1.name) }
            : []
        store.update { preferences in
            preferences.cloudflare.accountIDs = accountIDs
            preferences.cloudflare.projects = projects
            preferences.cloudflare.gitBranches = gitBranches
            preferences.cloudflare.showProduction = showProduction
            preferences.cloudflare.showPreview = showPreview
            preferences.cloudflare.showReady = showReady
            preferences.cloudflare.showBuilding = showBuilding
            preferences.cloudflare.showError = showError
            preferences.cloudflare.showQueued = showQueued
            preferences.cloudflare.showCanceled = showCanceled
            preferences.cloudflare.showSkipped = showSkipped
            preferences.cloudflare.limitByCount = Int(limitByCount) ?? 0
            preferences.cloudflare.limitByHours = Int(limitByHours)
        }
    }
}
