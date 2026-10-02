import Foundation
import Security

/// Keychain account name for each platform's API token.
enum TokenAccount: String {
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

/// Generic password items in the login keychain.
struct KeychainTokenStore: TokenStore {
    /// Fixed rather than derived from the bundle so the unbundled dev binary uses the same items as the app.
    static let service = "com.1orzero.open-deployment-menu-bar"

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
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}
