import Foundation
import Security

/// Keychain account name for each platform's API token.
enum TokenAccount: String, CaseIterable {
    case vercel
    case cloudflare
}

protocol TokenStore {
    /// The stored token, or nil when there is none or it cannot be read.
    func token(for account: TokenAccount) -> String?
    func setToken(_ token: String, for account: TokenAccount) throws
    /// Deleting a token that does not exist succeeds.
    func deleteToken(for account: TokenAccount) throws
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(message)"
    }
}

/// Generic password items, one per platform account, under a fixed service name.
struct KeychainTokenStore: TokenStore {
    enum Location {
        /// Synchronizable items in the data protection keychain. They sync through iCloud Keychain and live in the
        /// first keychain access group of the app's entitlements, which the Mac app, the iOS app and its widget share.
        case iCloud
        /// Items in the macOS login keychain, where versions up to 0.3.0 kept tokens.
        case loginKeychain
    }

    /// Fixed rather than derived from the bundle so every app and the widget address the same items.
    static let service = "com.1orzero.open-deployment-menu-bar"

    var location: Location = .iCloud

    func token(for account: TokenAccount) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// When the stored token last changed on any device; nil when there is no token.
    func modificationDate(for account: TokenAccount) -> Date? {
        var query = baseQuery(for: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let attributes = result as? [String: Any]
        else {
            return nil
        }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    func setToken(_ token: String, for account: TokenAccount) throws {
        let data = Data(token.utf8)
        let query = baseQuery(for: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            if location == .iCloud {
                // The widget refreshes while the phone is locked; synchronizable items cannot be device-only.
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func deleteToken(for account: TokenAccount) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for account: TokenAccount) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue,
        ]
        if location == .iCloud {
            query[kSecAttrSynchronizable as String] = true
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

enum TokenMigration {
    /// Moves every token from `source` into `destination`. A token already in `destination` wins; the source copy is
    /// deleted only once `destination` holds a token, so a failed write is retried on the next launch.
    static func move(from source: TokenStore, to destination: TokenStore) {
        for account in TokenAccount.allCases {
            guard let token = source.token(for: account), !token.isEmpty else { continue }
            if destination.token(for: account) == nil {
                do {
                    try destination.setToken(token, for: account)
                } catch {
                    NSLog("Keeping %@ token in the old store until next launch: %@", account.rawValue, error.localizedDescription)
                    continue
                }
            }
            do {
                try source.deleteToken(for: account)
            } catch {
                NSLog("Could not remove migrated %@ token from the old store: %@", account.rawValue, error.localizedDescription)
            }
        }
    }
}
