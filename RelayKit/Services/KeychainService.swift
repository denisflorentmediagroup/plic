// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import OSLog
import Security

/// A lightweight wrapper around the macOS Keychain for persisting the Matrix session token.
///
/// ``KeychainService`` stores a single blob of `Data` (the JSON-encoded session) under a
/// fixed service/account pair. It is used by ``MatrixService`` to save and restore sessions
/// across app launches, and by `KeychainSessionDelegate` to handle OIDC token refreshes.
nonisolated enum KeychainService: Sendable {
    nonisolated private static let logger = Logger(subsystem: "im.plic", category: "Keychain")

    private static let service = "im.plic"
    #if DEBUG
    private static let account = "matrix-session-debug"
    private static let storeKeyAccount = "store-key-debug"
    #else
    private static let account = "matrix-session"
    private static let storeKeyAccount = "store-key"
    #endif

    /// Length of the SQLite store key, in bytes. SQLCipher takes a 256-bit key.
    private static let storeKeyLength = 32

    // MARK: - Local store encryption key

    /// Returns the key that encrypts the SDK's SQLite stores, generating and
    /// persisting one on first use.
    ///
    /// The stores hold the Olm account, Megolm sessions and device keys — the
    /// material that makes past messages readable. Without a key they sit in
    /// plaintext on disk, where FileVault protects them only while the Mac is
    /// powered off.
    ///
    /// The key is stored with the same `ThisDeviceOnly` class as the session, so
    /// it never leaves this machine. Losing it makes the local store
    /// unreadable — which is the point, and why the caller must treat a `nil`
    /// return as "do not open the store" rather than "open it unencrypted".
    ///
    /// - Returns: 32 bytes of key material, or `nil` if the Keychain refused
    ///   both the read and the write.
    static func loadOrCreateStoreKey() -> Data? {
        switch lookUpStoreKey() {
        case .found(let existing):
            return existing
        case .failed(let status):
            // The key may exist and simply not be readable right now. Minting
            // one here would be guessing; the caller refuses to open storage
            // instead, and can try again.
            logger.error("Could not read the store key (OSStatus \(status))")
            return nil
        case .notFound:
            break
        }

        var key = Data(count: storeKeyLength)
        let generated = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, storeKeyLength, base)
        }
        guard generated == errSecSuccess else {
            logger.error("Could not generate a store key (OSStatus \(generated))")
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // macOS writes to the legacy file-based keychain unless this is set, and
            // that keychain silently ignores kSecAttrAccessible.
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storeKeyAccount,
            kSecAttrAccessGroup as String: AppGroup.identifier,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            // A duplicate means a key already exists — perhaps written between
            // our read and this add, or by a path the read missed. That key is
            // the truth: read it back and use it. Returning nil here would be
            // the one outcome worse than any failure, because callers treat it
            // as "open the store unencrypted".
            if status == errSecDuplicateItem, let existing = loadStoreKey() {
                return existing
            }
            logger.error("Could not persist the store key (OSStatus \(status))")
            return nil
        }
        logger.info("Generated a new local store encryption key")
        return key
    }

    /// Whether a store key is already held, without creating one.
    ///
    /// ``loadOrCreateStoreKey()`` cannot answer this: it mints a key when none
    /// exists, which is right for opening a store and useless for asking
    /// whether an existing store can still be read. Callers use this to tell
    /// "first run" from "the key that encrypted this data is gone".
    static func hasStoreKey() -> Bool {
        loadStoreKey() != nil
    }

    /// What a Keychain lookup found.
    ///
    /// "Not there" and "could not look" are different answers. Collapsed into
    /// one, a Keychain that merely failed to answer reads as a session that
    /// was never saved — sending the user to sign in again as a new device —
    /// or as a key that is gone, whose recovery clears local data the key
    /// could still open.
    enum Lookup {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    static func lookUp(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // macOS writes to the legacy file-based keychain unless this is set, and
            // that keychain silently ignores kSecAttrAccessible.
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    /// The saved Matrix session, distinguishing absence from failure.
    static func lookUpSession() -> Lookup {
        lookUp(account: account)
    }

    /// The local store key, distinguishing absence from failure. A key of the
    /// wrong length is reported as a failure, never as absent: absent leads to
    /// minting a replacement.
    static func lookUpStoreKey() -> Lookup {
        let lookup = lookUp(account: storeKeyAccount)
        if case .found(let key) = lookup, key.count != storeKeyLength {
            return .failed(errSecDecode)
        }
        return lookup
    }

    private static func loadStoreKey() -> Data? {
        if case .found(let key) = lookUpStoreKey() { return key }
        return nil
    }

    /// Saves session data to the keychain, replacing any previously stored value.
    ///
    /// The item is written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
    /// it is readable only while the Mac is unlocked, and — unlike the plain
    /// `WhenUnlocked` class — it is excluded from backups and never migrates to
    /// another machine. A Matrix session token grants full account access, so it
    /// should not survive a restore onto hardware the user no longer controls.
    ///
    /// - Parameter data: The encoded session data to persist.
    /// - Returns: `true` if the item was written. Callers that ignore this get
    ///   the previous silent-failure behaviour, so prefer to check it.
    @discardableResult
    static func save(_ data: Data) -> Bool {
        save(data, account: account)
    }

    /// Account-parameterised variant.
    ///
    /// Exists so tests can exercise the update-or-add semantics against a
    /// scratch account. Touching the real session account from a test would
    /// destroy the developer's live login — the test host shares this
    /// keychain.
    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        // Update in place when an item exists, add otherwise. The previous
        // delete-then-add destroyed the stored session *before* attempting the
        // new write, so a transient failure — during an OIDC token refresh, say
        // — logged the user out on the next launch. An update that fails leaves
        // the old value untouched.
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // macOS writes to the legacy file-based keychain unless this is set, and
            // that keychain silently ignores kSecAttrAccessible.
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.identifier
        ]
        let changes: [String: Any] = [
            kSecValueData as String: data,
            // Reasserted on update so an item written by an older build is
            // migrated to the stricter class rather than keeping whatever it had.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // Losing this write means the next launch silently lands on the login
            // screen with no explanation, so make the cause visible.
            logger.error("Keychain write failed (OSStatus \(status)); session will not persist")
        }
        return status == errSecSuccess
    }

    /// Removes items this app wrote to the legacy file-based keychain before
    /// the data-protection flag was added.
    ///
    /// Builds prior to that flag stored the session in `login.keychain-db`,
    /// where `ThisDeviceOnly` is silently ignored — so a real access token
    /// could ride along in backups and keychain migration. Those items are
    /// invisible to every current query, which all set the flag; this is the
    /// one deliberate exception. Runs at startup, idempotent, safe when there
    /// is nothing to remove.
    static func purgeLegacyItems() {
        // One-time cleanup. Nothing writes to the legacy keychain any more, so
        // after a single successful pass there is nothing left to find, and
        // re-running a delete keyed on the live session's own account every
        // launch is risk with no upside.
        let marker = "im.plic.legacyKeychainPurged"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        purgeLegacyItems(accounts: [account, storeKeyAccount])
        UserDefaults.standard.set(true, forKey: marker)
    }

    /// Account-parameterised variant.
    ///
    /// Exists so tests can run the real purge against a scratch account. See
    /// ``save(_:account:)`` for why tests must not touch the live accounts.
    static func purgeLegacyItems(accounts: [String]) {
        for legacyAccount in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                // Explicitly the legacy file-based keychain, and only it.
                // Omitting this does not mean "legacy only" — the query also
                // matches data-protection items, so this delete found the live
                // session under the very account it names and removed it. The
                // user signed in, quit, reopened, and was met with the login
                // screen. LegacyPurgeScopeTests holds this line in place.
                kSecUseDataProtectionKeychain as String: false,
                kSecAttrService as String: service,
                kSecAttrAccount as String: legacyAccount
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                logger.info("Removed a legacy-keychain item (account: \(legacyAccount, privacy: .public))")
            }
        }
    }

    /// Loads the previously saved session data from the keychain.
    ///
    /// - Returns: The stored session data, or `nil` if no session is saved.
    static func load() -> Data? {
        load(account: account)
    }

    /// Account-parameterised variant, for tests. See ``save(_:account:)``.
    static func load(account: String) -> Data? {
        if case .found(let data) = lookUp(account: account) { return data }
        return nil
    }

    /// Deletes the stored session data from the keychain.
    static func delete() {
        delete(account: account)
    }

    /// Deletes the store key. Done on sign-out, once the stores it protected
    /// are gone: the next account gets a key of its own.
    static func deleteStoreKey() {
        delete(account: storeKeyAccount)
    }

    /// Account-parameterised variant, for tests. See ``save(_:account:)``.
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // macOS writes to the legacy file-based keychain unless this is set, and
            // that keychain silently ignores kSecAttrAccessible.
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.identifier
        ]
        SecItemDelete(query as CFDictionary)
    }
}
