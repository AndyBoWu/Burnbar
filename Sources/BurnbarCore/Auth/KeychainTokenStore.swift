import Foundation
import Security

/// Stores the GitHub access token in the macOS login Keychain under **our own**
/// service id `xyz.andybowu.Burnbar.github-token`.
///
/// Privacy thesis (CLAUDE.md, M3): the Keychain is used *only* for Burnbar's own
/// `xyz.andybowu.Burnbar.*` service ids — never a third-party Keychain item, and
/// never browser secrets. This is the single Keychain access Burnbar performs.
///
/// The token is written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// a device-only accessibility class, so it never syncs to iCloud Keychain and
/// never leaves the machine.
///
/// The store holds no mutable state — it is a thin value wrapper over the
/// Security framework's C API — so it is safe to share across concurrency
/// domains (`Sendable`).
public struct KeychainTokenStore: Sendable {
    /// Production service id. The only Keychain service Burnbar ever touches.
    public static let defaultService = "xyz.andybowu.Burnbar.github-token"

    /// Fixed account label under the service. A single token is stored, so one
    /// stable account is sufficient and makes upserts unambiguous.
    public static let defaultAccount = "github-access-token"

    /// Failures surfaced by the underlying Security framework calls.
    ///
    /// `OSStatus` codes are preserved so callers (and tests) can distinguish a
    /// genuine error from "no item found".
    public enum KeychainError: Error, Equatable, Sendable {
        /// A `SecItem*` call returned a non-success, non-`errSecItemNotFound`
        /// status. The associated value is the raw `OSStatus`.
        case unexpectedStatus(OSStatus)
        /// A stored item existed but its data was not valid UTF-8 — i.e. it was
        /// not written by this store. Treated as a hard error rather than a
        /// silent `nil` so corruption is visible.
        case dataNotUTF8
    }

    /// Keychain service id this instance reads/writes under. Injectable so tests
    /// can use a throwaway `xyz.andybowu.Burnbar.test-…` service and never touch
    /// the real production item.
    public let service: String

    /// Account label paired with ``service`` for every query.
    public let account: String

    /// - Parameters:
    ///   - service: Keychain service id. Defaults to the production
    ///     `xyz.andybowu.Burnbar.github-token`.
    ///   - account: Account label. Defaults to a fixed single-token label.
    public init(
        service: String = KeychainTokenStore.defaultService,
        account: String = KeychainTokenStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    /// Save (upsert) `token` under ``service`` / ``account``.
    ///
    /// If an item already exists it is updated in place via `SecItemUpdate`;
    /// otherwise a new item is added via `SecItemAdd`. The item is marked
    /// `…ThisDeviceOnly` so it never syncs to iCloud Keychain.
    ///
    /// - Parameter token: UTF-8 token text to persist.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` if the Keychain call
    ///   fails.
    public func save(token: String) throws {
        let tokenData = Data(token.utf8)

        // Try an in-place update first so we never accumulate duplicate items.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: tokenData] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break // fall through to add
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = tokenData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Read the stored token, if present.
    ///
    /// - Returns: The token, or `nil` when no item exists under
    ///   ``service`` / ``account``.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` on a Keychain failure,
    ///   or ``KeychainError/dataNotUTF8`` if a stored item is not decodable.
    public func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedStatus(status)
            }
            guard let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataNotUTF8
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Delete the stored token. A no-op (no error) when no item exists.
    ///
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` on a Keychain failure
    ///   other than "item not found".
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// The class/service/account triple shared by every query. `read`/`save`/
    /// `delete` augment this with operation-specific keys.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
