import XCTest
@testable import open_deployment_menu_bar

final class PreferencesStoreTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    func testCopiesLegacySettingsWhenCurrentDomainIsEmpty() throws {
        let current = makeDefaults()
        let legacy = makeDefaults()
        let legacyPreferences = preferences(teamId: "team_old")
        legacy.set(try JSONEncoder().encode(legacyPreferences), forKey: PreferencesStore.storageKey)

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: legacy, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(store.current, legacyPreferences)
        let persisted = try XCTUnwrap(current.data(forKey: PreferencesStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: persisted), legacyPreferences)
        XCTAssertNotNil(legacy.data(forKey: PreferencesStore.storageKey), "Legacy domain must be left intact")
    }

    func testDoesNotOverwriteExistingSettings() throws {
        let current = makeDefaults()
        let legacy = makeDefaults()
        let existing = preferences(teamId: "team_new")
        current.set(try JSONEncoder().encode(existing), forKey: PreferencesStore.storageKey)
        legacy.set(try JSONEncoder().encode(preferences(teamId: "team_old")), forKey: PreferencesStore.storageKey)

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: legacy, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(store.current, existing)
    }

    func testMigratesPlaintextTokenAndClearsItFromBothDomains() throws {
        let current = makeDefaults()
        let legacy = makeDefaults()
        try storePlaintext(preferences(teamId: "team_new"), token: "current-token", in: current)
        try storePlaintext(
            preferences(teamId: "team_old"),
            token: "legacy-token",
            extra: ["legacyOnlySetting": "kept"],
            in: legacy
        )
        let tokenStore = InMemoryTokenStore()

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: legacy, tokenStore: tokenStore)

        XCTAssertEqual(tokenStore.tokens[.vercel], "current-token")
        XCTAssertEqual(store.token(for: .vercel), "current-token")
        XCTAssertEqual(store.current, preferences(teamId: "team_new"))

        let currentObject = try storedObject(in: current)
        XCTAssertNil(currentObject[PreferencesStore.plaintextTokenKey])
        XCTAssertEqual(currentObject["teamId"] as? String, "team_new")

        let legacyObject = try storedObject(in: legacy)
        XCTAssertNil(legacyObject[PreferencesStore.plaintextTokenKey])
        XCTAssertEqual(legacyObject["teamId"] as? String, "team_old")
        XCTAssertEqual(legacyObject["legacyOnlySetting"] as? String, "kept")
        XCTAssertEqual(legacyObject["showPreview"] as? Bool, false)
    }

    func testMigratesLegacyTokenWhenCurrentDomainIsEmpty() throws {
        let current = makeDefaults()
        let legacy = makeDefaults()
        try storePlaintext(preferences(teamId: "team_old"), token: "legacy-token", in: legacy)
        let tokenStore = InMemoryTokenStore()

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: legacy, tokenStore: tokenStore)

        XCTAssertEqual(tokenStore.tokens[.vercel], "legacy-token")
        XCTAssertEqual(store.current, preferences(teamId: "team_old"))
        XCTAssertNil(try storedObject(in: current)[PreferencesStore.plaintextTokenKey])
        XCTAssertNil(try storedObject(in: legacy)[PreferencesStore.plaintextTokenKey])
    }

    func testFailedTokenWriteLeavesBothDomainsUnchanged() throws {
        let current = makeDefaults()
        let legacy = makeDefaults()
        try storePlaintext(preferences(teamId: "team_new"), token: "current-token", in: current)
        try storePlaintext(preferences(teamId: "team_old"), token: "legacy-token", in: legacy)
        let currentBefore = current.data(forKey: PreferencesStore.storageKey)
        let legacyBefore = legacy.data(forKey: PreferencesStore.storageKey)

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: legacy, tokenStore: FailingTokenStore())

        XCTAssertEqual(current.data(forKey: PreferencesStore.storageKey), currentBefore)
        XCTAssertEqual(legacy.data(forKey: PreferencesStore.storageKey), legacyBefore)
        XCTAssertNil(store.token(for: .vercel))
        XCTAssertEqual(store.current, preferences(teamId: "team_new"))

        // Saving other settings must not drop the plaintext token the next launch retries.
        store.update { $0.gitBranches = "main" }
        let currentObject = try storedObject(in: current)
        XCTAssertEqual(currentObject[PreferencesStore.plaintextTokenKey] as? String, "current-token")
        XCTAssertEqual(currentObject["gitBranches"] as? String, "main")
    }

    func testExistingStoredTokenIsNotOverwrittenButPlaintextIsCleared() throws {
        let current = makeDefaults()
        let legacy = makeDefaults()
        try storePlaintext(preferences(teamId: "team_new"), token: "current-token", in: current)
        try storePlaintext(preferences(teamId: "team_old"), token: "legacy-token", in: legacy)
        let tokenStore = InMemoryTokenStore(tokens: [.vercel: "keychain-token"])

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: legacy, tokenStore: tokenStore)

        XCTAssertEqual(tokenStore.tokens[.vercel], "keychain-token")
        XCTAssertEqual(store.token(for: .vercel), "keychain-token")
        XCTAssertNil(try storedObject(in: current)[PreferencesStore.plaintextTokenKey])
        XCTAssertNil(try storedObject(in: legacy)[PreferencesStore.plaintextTokenKey])
    }

    func testClearingTokenDeletesStoredToken() throws {
        let tokenStore = InMemoryTokenStore(tokens: [.vercel: "keychain-token"])
        let store = PreferencesStore(userDefaults: makeDefaults(), legacyUserDefaults: nil, tokenStore: tokenStore)
        XCTAssertEqual(store.token(for: .vercel), "keychain-token")

        try store.setToken("  \n", for: .vercel)

        XCTAssertNil(tokenStore.tokens[.vercel])
        XCTAssertNil(store.token(for: .vercel))
    }

    func testSettingsSavedBeforeCloudflareSupportGetDefaults() throws {
        let current = makeDefaults()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences(teamId: "team_old"))) as? [String: Any]
        )
        object.removeValue(forKey: "cloudflare")
        object.removeValue(forKey: "general")
        current.set(try JSONSerialization.data(withJSONObject: object), forKey: PreferencesStore.storageKey)

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: nil, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(store.current.teamId, "team_old")
        XCTAssertEqual(store.current.showPreview, false)
        XCTAssertEqual(store.current.cloudflare, .default)
        XCTAssertEqual(store.current.general.menuLayout, .byTime)
    }

    func testUnrecognizedMenuLayoutFallsBackToByTime() throws {
        let current = makeDefaults()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences(teamId: "team_new"))) as? [String: Any]
        )
        object["general"] = ["menuLayout": "byProject"]
        current.set(try JSONSerialization.data(withJSONObject: object), forKey: PreferencesStore.storageKey)

        let store = PreferencesStore(userDefaults: current, legacyUserDefaults: nil, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(store.current.teamId, "team_new")
        XCTAssertEqual(store.current.general.menuLayout, .byTime)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "PreferencesStoreTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func preferences(teamId: String) -> Preferences {
        var preferences = Preferences.default
        preferences.teamId = teamId
        preferences.showPreview = false
        return preferences
    }

    /// Writes settings the way versions before Keychain storage did, with the token inside the JSON.
    private func storePlaintext(
        _ preferences: Preferences,
        token: String,
        extra: [String: Any] = [:],
        in defaults: UserDefaults
    ) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]
        )
        object[PreferencesStore.plaintextTokenKey] = token
        object.merge(extra) { _, new in new }
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: PreferencesStore.storageKey)
    }

    private func storedObject(in defaults: UserDefaults) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class InMemoryTokenStore: TokenStore {
    private(set) var tokens: [TokenAccount: String]

    init(tokens: [TokenAccount: String] = [:]) {
        self.tokens = tokens
    }

    func token(for account: TokenAccount) -> String? {
        tokens[account]
    }

    func setToken(_ token: String, for account: TokenAccount) throws {
        tokens[account] = token
    }

    func deleteToken(for account: TokenAccount) throws {
        tokens[account] = nil
    }
}

private struct FailingTokenStore: TokenStore {
    struct WriteFailed: Error {}

    func token(for account: TokenAccount) -> String? {
        nil
    }

    func setToken(_ token: String, for account: TokenAccount) throws {
        throw WriteFailed()
    }

    func deleteToken(for account: TokenAccount) throws {
        throw WriteFailed()
    }
}
