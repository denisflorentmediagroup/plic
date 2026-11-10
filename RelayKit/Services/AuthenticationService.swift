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

import CryptoKit
import Foundation
import os
import RelayInterface
import Synchronization

private let logger = Logger(subsystem: "im.plic", category: "Authentication")

/// The persisted representation of a Matrix session, stored in the keychain.
///
/// Both ``AuthenticationService`` and ``KeychainSessionDelegate`` use this type
/// to encode/decode session data, ensuring a single source of truth.
///
/// Marked `nonisolated` so that `Codable` conformance can be used from any
/// isolation context (e.g. the nonisolated ``KeychainSessionDelegate``).
nonisolated struct StoredSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var userId: String
    var deviceId: String
    var homeserverUrl: String
    var oauthData: String?
}

/// Outcome of an attempt to restore a previously saved session.
///
/// Distinguishes "no keychain session at all" (→ login screen) from
/// "session exists but we couldn't reach the homeserver" (→ restore
/// the user into a cache-only experience and retry once connectivity
/// returns).
enum RestoreOutcome {
    /// No saved session in the keychain. Caller should show login.
    case noSavedSession
    /// Session restored successfully and is ready for sync.
    case restored(ClientProxy, userId: String)
    /// A session is saved but the homeserver couldn't be reached
    /// (no network, well-known discovery failed, connection timed out).
    /// Caller should treat the user as logged-in but with sync stuck
    /// offline, and retry the full restore when connectivity returns.
    case offlineWithSavedSession(userId: String, homeserverUrl: String)
    /// A session is saved and local data exists, but the key that encrypted
    /// it is gone from the Keychain. The data is permanently unreadable —
    /// that is what encrypting it bought — so the caller must explain rather
    /// than show a login screen that makes it look like the messages were
    /// lost.
    case localDataUnreadable(userId: String)
    /// The Keychain would not supply the key that encrypts local data, so no
    /// client was built. Distinct from ``localDataUnreadable(userId:)``: the key
    /// may well still exist, and trying again once the Keychain responds can
    /// succeed.
    case keychainUnavailable
    /// A session is saved but restore failed for a non-network reason
    /// (auth invalidated, schema mismatch, etc.). Caller should show
    /// an error.
    case failed(Error)
}

/// Handles Matrix authentication: password login, OAuth/OIDC, session restore, and logout.
///
/// ``AuthenticationService`` encapsulates all authentication-related logic, including
/// building SDK clients via ``ClientBuilderProxy``, managing keychain-persisted sessions,
/// and coordinating OAuth browser flows. It produces an authenticated ``ClientProxy`` that
/// the caller (``MatrixService``) retains for further operations.
///
/// The OAuth browser flow is decoupled from this service: callers provide an `openURL`
/// closure that opens the authorization URL and returns the callback URL. This allows
/// SwiftUI views to use `@Environment(\.webAuthenticationSession)` without coupling
/// the service to AppKit or AuthenticationServices.
/// Thrown when the Keychain will not supply the local store key.
///
/// Plic stores nothing unencrypted, so without the key it stores nothing: no
/// client is built at all.
struct KeychainUnavailableError: Error {}

/// The homeserver answered over plain `http`, which would carry the password
/// and every access token in the clear.
struct InsecureHomeserverError: LocalizedError {
    let homeserver: String

    var errorDescription: String? {
        "\(homeserver) is not an https server. Plic only signs in over https."
    }
}

@MainActor
final class AuthenticationService {

    private let networkMonitor: NetworkMonitor
    var activityLog: ActivityLog?

    /// Where the local store key comes from. The Keychain in the app; a stub in
    /// tests, which is the only way to exercise a Keychain that refuses.
    private let storeKey: () -> Data?

    init(networkMonitor: NetworkMonitor, storeKey: @escaping () -> Data? = KeychainService.loadOrCreateStoreKey) {
        self.networkMonitor = networkMonitor
        self.storeKey = storeKey
        // One-time cleanup: builds before the data-protection flag left session
        // tokens in the legacy keychain, outside ThisDeviceOnly protection.
        KeychainService.purgeLegacyItems()
    }

    // MARK: - Data Paths

    /// Where the local message search index lives.
    ///
    /// Kept apart from the SDK's own stores because its lifecycle differs: it
    /// can be deleted and rebuilt without touching crypto state.
    static var searchIndexDirectory: URL {
        let url = applicationSupport.appending(path: searchIndexSubdirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
        return url
    }

    /// Keeps a directory out of Time Machine and other backups.
    ///
    /// The store and the index hold every decrypted message, under a key
    /// that lives only in this Mac's Keychain. Encrypted or not, a copy on a
    /// backup disk is a copy nobody asked for, and one that outlives sign-out.
    static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    #if DEBUG
    private static let searchIndexSubdirectory = "Relay/search-index-debug"
    #else
    private static let searchIndexSubdirectory = "Relay/search-index"
    #endif

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Records which key wrote the index currently on disk.
    ///
    /// Beside the index rather than inside it: the SDK owns that directory and
    /// replaces its contents wholesale.
    static var searchIndexStampURL: URL {
        applicationSupport.appending(path: searchIndexSubdirectory + ".keycheck")
    }

    /// The index directory to hand the client builder, with any index written
    /// by a different key discarded first.
    ///
    /// The index is encrypted with the Keychain store key, but nothing on disk
    /// recorded *which* key. Change that key — a Keychain reset, a restore onto
    /// another Mac, the legacy purge this app once shipped — and the SDK opens
    /// the stale index and fails per room, mid-search, with "invalid MAC of the
    /// store key". The SQLite stores have a recovery path for exactly that
    /// (``RestoreOutcome/localDataUnreadable(userId:)``); the index had none, so
    /// it stayed broken for good, one alert per keystroke.
    ///
    /// Discarding is the whole answer: the index is derived data, rebuilt from
    /// the store, so there is nothing to preserve and no decision worth putting
    /// in front of anyone.
    static func prepareSearchIndexDirectory(password: String) -> URL {
        let directory = searchIndexDirectory
        if reconcileSearchIndex(directory: directory, stamp: searchIndexStampURL, password: password) {
            logger.info("Discarded a search index written under a different store key")
        }
        return directory
    }

    /// The comparison behind ``prepareSearchIndexDirectory(password:)``, with
    /// both paths passed in so tests never reach the live index.
    ///
    /// - Returns: `true` when an existing index was discarded.
    @discardableResult
    static func reconcileSearchIndex(directory: URL, stamp: URL, password: String) -> Bool {
        let current = searchIndexFingerprint(of: password)
        guard (try? String(contentsOf: stamp, encoding: .utf8)) != current else { return false }

        // An unstamped index predates this check. It may well be readable, but
        // nothing on disk says so — and rebuilding costs time, where guessing
        // wrong costs a feature that never works again.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let discarded = !existing.isEmpty
        if discarded {
            try? FileManager.default.removeItem(at: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        try? current.write(to: stamp, atomically: true, encoding: .utf8)
        return discarded
    }

    /// Drops the stamp so the next launch rebuilds the index.
    ///
    /// For when the SDK reports the index unreadable anyway — corruption rather
    /// than a key change. An index cannot be replaced underneath a client that
    /// holds it open, so the repair waits one launch, which is exactly what the
    /// message shown to the user promises.
    static func invalidateSearchIndexStamp() {
        try? FileManager.default.removeItem(at: searchIndexStampURL)
    }

    /// A domain-separated digest of the index password.
    ///
    /// The stamp sits unprotected beside the index, so it holds a hash and
    /// never the key itself. It only has to answer "same key or not".
    private static func searchIndexFingerprint(of password: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("im.plic.search-index.key-check.v1".utf8))
        hasher.update(data: Data(password.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static var dataDirectory: URL {
        #if DEBUG
        let subdirectory = "Relay/matrix-data-debug"
        #else
        let subdirectory = "Relay/matrix-data"
        #endif

        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
        return url
    }

    static var cacheDirectory: URL {
        #if DEBUG
        let subdirectory = "Relay/matrix-cache-debug"
        #else
        let subdirectory = "Relay/matrix-cache"
        #endif

        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether the SDK's data directory holds anything worth a key.
    ///
    /// An empty or absent directory is a first run, not a loss.
    static func hasLocalStoreData() -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: dataDirectory.path
        )
        return !(contents ?? []).isEmpty
    }

    static func resetLocalSessionData() {
        // swiftlint:disable:next identifier_name
        let fm = FileManager.default
        try? fm.removeItem(at: dataDirectory)
        try? fm.removeItem(at: cacheDirectory)
    }

    /// Removes every local store, including the search index.
    ///
    /// ``resetLocalSessionData()`` deliberately leaves the search index alone,
    /// because it is rebuilt from a working store. When the store key is gone
    /// the index is encrypted with that same missing key and is just as
    /// unreadable, so recovering from that state has to take it too.
    static func resetAllLocalData() {
        resetLocalSessionData()
        try? FileManager.default.removeItem(at: searchIndexDirectory)
        try? FileManager.default.removeItem(at: searchIndexStampURL)
    }

    /// Deletes only the rebuildable cache directory (sync state, timeline events),
    /// preserving the data directory (crypto store, device identity).
    static func resetCacheData() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// The active session delegate, scoped to the current client lifecycle.
    ///
    /// A new delegate is created for each login/restore so that stale
    /// callbacks from a previous SDK client cannot overwrite the new
    /// session's tokens in the keychain.
    private var sessionDelegate = KeychainSessionDelegate()

    // MARK: - Builder Helpers

    /// Creates a ``ClientBuilderProxy`` with common configuration applied.
    ///
    /// Internal rather than private so `SecurityPolicyTests` can assert that
    /// the security posture — recipient strategy, store encryption, encrypted
    /// search index, user agent — actually reaches the builder. Every one of
    /// those guarantees is a single call in this method, and nothing else in
    /// the app would notice if one quietly disappeared.
    ///
    /// - Throws: ``KeychainUnavailableError`` when the Keychain will not supply
    ///   the store key. There is no unencrypted fallback: a store anyone with
    ///   the disk could read is the one outcome worse than not starting.
    func makeBuilder() throws -> ClientBuilderProxy {
        guard let key = storeKey() else {
            activityLog?.log(
                category: .auth, severity: .error, source: "AuthenticationService",
                summary: "Keychain refused the store key — not opening local storage"
            )
            throw KeychainUnavailableError()
        }

        // Invalidate the previous delegate so any lingering SDK callbacks
        // from an old client are silently dropped.
        sessionDelegate.invalidate()
        sessionDelegate = KeychainSessionDelegate()
        sessionDelegate.activityLog = activityLog

        let builder = ClientBuilderProxy()
            // Encrypts the Olm account, Megolm sessions, device keys, cached
            // events and cached media at rest. The key lives in the Keychain,
            // ThisDeviceOnly.
            .encryptedSqliteStore(
                dataPath: Self.dataDirectory.path,
                cachePath: Self.cacheDirectory.path,
                key: key
            )
            .slidingSyncVersionBuilder(.discoverNative)
            .autoEnableCrossSigning(true)
            .autoEnableBackups(true)
            // Threads live in a panel of their own; the SDK keeps them and
            // their summaries current only when told to.
            .threadsEnabled(true, subscriptions: false)
            // MSC4153: only send room keys to devices signed by their owner's
            // published identity. Element switches this on in October 2026; Plic
            // ships it on from the start, so an unverified device never receives
            // keys rather than receiving them until a deadline passes.
            .roomKeyRecipientStrategy(.identityBasedStrategy)
            .userAgent("Plic")
            .setSessionDelegate(sessionDelegate)

        // The index holds decrypted message text, so it is encrypted with the
        // same key as the stores: it warrants exactly their protection, and one
        // key is one thing to lose rather than two.
        let password = key.base64EncodedString()
        builder.searchIndexStore(
            path: Self.prepareSearchIndexDirectory(password: password).path,
            password: password
        )

        return builder
    }

    // MARK: - Session Restore

    /// Attempts to restore a previously saved session from the keychain.
    ///
    /// Distinguishes "no saved session" from "homeserver couldn't be
    /// reached" so the caller (``MatrixService``) can choose between
    /// going to the login screen and entering an offline-restored
    /// cache-only state. See ``RestoreOutcome``.
    func restoreSession() async -> RestoreOutcome {
        let data: Data
        switch KeychainService.lookUpSession() {
        case .found(let saved):
            data = saved
        case .notFound:
            activityLog?.log(
                category: .auth, severity: .info, source: "AuthenticationService",
                summary: "No saved session in keychain"
            )
            return .noSavedSession
        case .failed(let status):
            // Not "no session": a Keychain that did not answer. Treating it as
            // absent would send the user to sign in again as a new device.
            activityLog?.log(
                category: .auth, severity: .error, source: "AuthenticationService",
                summary: "Keychain did not answer for the saved session",
                detail: "OSStatus \(status)"
            )
            return .keychainUnavailable
        }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            activityLog?.log(
                category: .auth, severity: .warning, source: "AuthenticationService",
                summary: "Saved session could not be decoded"
            )
            return .noSavedSession
        }

        // If the radio is off, don't even try `buildClient()` — well-known
        // discovery would just fail. Skip straight to offline-restore so
        // the user sees their cached data instead of the login screen.
        guard networkMonitor.isConnected else {
            activityLog?.log(
                category: .auth, severity: .info, source: "AuthenticationService",
                summary: "Restoring session offline",
                metadata: ["userId": stored.userId]
            )
            return .offlineWithSavedSession(
                userId: stored.userId,
                homeserverUrl: stored.homeserverUrl
            )
        }

        // Data on disk with no key to open it. Checked before building,
        // because building would mint a fresh key and then fail deep inside
        // the SDK with a message about SQLite that means nothing to anyone.
        if Self.hasLocalStoreData() {
            switch KeychainService.lookUpStoreKey() {
            case .found:
                break
            case .notFound:
                activityLog?.log(
                    category: .auth, severity: .error, source: "AuthenticationService",
                    summary: "Local store key is missing — cached data cannot be decrypted",
                    metadata: ["userId": stored.userId]
                )
                return .localDataUnreadable(userId: stored.userId)
            case .failed(let status):
                // Not a lost key: a Keychain that did not answer. Reporting it
                // as lost would lead to "Clear Local Data" and destroy a store
                // that its key can still open.
                activityLog?.log(
                    category: .auth, severity: .error, source: "AuthenticationService",
                    summary: "Keychain did not answer for the store key",
                    detail: "OSStatus \(status)"
                )
                return .keychainUnavailable
            }
        }

        do {
            activityLog?.log(
                category: .auth, severity: .debug, source: "AuthenticationService",
                summary: "Restoring session",
                metadata: ["userId": stored.userId]
            )

            let client = try await makeBuilder()
                .serverNameOrHomeserverUrl(stored.homeserverUrl)
                .buildClient()

            let session = Session(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                userId: stored.userId,
                deviceId: stored.deviceId,
                homeserverUrl: stored.homeserverUrl,
                oauthData: stored.oauthData,
                slidingSyncVersion: .native
            )
            try await client.restoreSession(session: session)

            let clientProxy = try ClientProxy(client: client)
            activityLog?.log(
                category: .auth, severity: .info, source: "AuthenticationService",
                summary: "Session restored from keychain",
                metadata: ["userId": stored.userId]
            )
            return .restored(clientProxy, userId: stored.userId)
        } catch is KeychainUnavailableError {
            return .keychainUnavailable
        } catch {
            if NetworkErrorClassifier.isOfflineShaped(error) {
                activityLog?.log(
                    category: .auth, severity: .warning, source: "AuthenticationService",
                    summary: "Session restore deferred — homeserver unreachable",
                    detail: error.localizedDescription
                )
                return .offlineWithSavedSession(
                    userId: stored.userId,
                    homeserverUrl: stored.homeserverUrl
                )
            }
            activityLog?.log(
                category: .auth, severity: .error, source: "AuthenticationService",
                summary: "Session restore failed",
                detail: error.localizedDescription
            )
            return .failed(error)
        }
    }

    // MARK: - Password Login

    /// Authenticates with the homeserver using a username and password.
    ///
    /// - Parameters:
    ///   - username: The Matrix username.
    ///   - password: The account password.
    ///   - homeserver: The homeserver URL or server name.
    /// - Returns: The authenticated ``ClientProxy`` and the user's Matrix ID.
    /// Refuses a homeserver reached over anything but `https`.
    ///
    /// The SDK accepts whatever the server name's well-known file points at,
    /// `http://` included, and the user typing a bare name would never see
    /// it. Debug builds exempt this Mac and its network, where the test
    /// server runs in the clear.
    static func requireSecureHomeserver(_ homeserver: String) throws {
        guard let url = URL(string: homeserver), url.scheme?.lowercased() == "https" else {
            #if DEBUG
            if let host = URL(string: homeserver)?.host(), LocalNetworkHost.contains(host) { return }
            #endif
            throw InsecureHomeserverError(homeserver: homeserver)
        }
    }

    func login(username: String, password: String, homeserver: String) async throws -> (ClientProxy, String) {
        Self.resetLocalSessionData()

        let client = try await makeBuilder()
            .serverNameOrHomeserverUrl(homeserver)
            .buildClient()
        try Self.requireSecureHomeserver(client.homeserver())

        try await client.login(
            username: username,
            password: password,
            initialDeviceName: "Plic",
            deviceId: nil
        )

        let session = try client.session()
        saveSession(session)

        let clientProxy = try ClientProxy(client: client)
        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "Password login succeeded",
            metadata: ["userId": session.userId]
        )
        return (clientProxy, session.userId)
    }

    // MARK: - OAuth Login


    /// Initiates an OAuth/OIDC login flow, using the provided closure to open the browser.
    ///
    /// The `openURL` closure receives the OIDC authorization URL and must return the
    /// callback URL after the user completes authentication. Callers typically implement
    /// this using SwiftUI's `WebAuthenticationSession` environment value.
    ///
    /// - Parameters:
    ///   - homeserver: The homeserver URL or server name.
    ///   - openURL: A closure that opens the authorization URL in a browser and returns
    ///     the callback URL.
    /// - Returns: The authenticated ``ClientProxy`` and the user's Matrix ID.
    /// - Throws: If the homeserver doesn't support OIDC, the browser flow fails, or the
    ///   user cancels.
    func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws -> (ClientProxy, String) {
        Self.resetLocalSessionData()

        let client = try await makeBuilder()
            .serverNameOrHomeserverUrl(homeserver)
            .buildClient()
        try Self.requireSecureHomeserver(client.homeserver())

        let loginDetails = await client.homeserverLoginDetails()
        guard loginDetails.supportsOauthLogin() else {
            activityLog?.log(
                category: .auth, severity: .warning, source: "AuthenticationService",
                summary: "Homeserver does not support OIDC",
                metadata: ["homeserver": homeserver]
            )
            throw RelayError.oauthNotSupported
        }

        let oauthConfig = OAuthConfiguration(
            clientName: "Plic",
            redirectUri: OAuthClientIdentity.redirectURI,
            clientUri: OAuthClientIdentity.clientURI,
            logoUri: OAuthClientIdentity.logoURI,
            tosUri: nil,
            policyUri: OAuthClientIdentity.policyURI,
            staticRegistrations: [:]
        )

        let authData = try await client.urlForOauth(
            oauthConfiguration: oauthConfig,
            prompt: nil,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )

        let loginURL = authData.loginUrl()
        guard let url = URL(string: loginURL) else {
            throw RelayError.oauthInvalidURL
        }

        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "OAuth login flow started"
        )

        let callbackURL = try await openURL(url)

        try await client.loginWithOauthCallback(callbackUrl: callbackURL.absoluteString)

        let session = try client.session()
        saveSession(session)

        let clientProxy = try ClientProxy(client: client)
        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "OAuth login succeeded",
            metadata: ["userId": session.userId]
        )
        return (clientProxy, session.userId)
    }

    /// Clears the persisted session and local SDK data.
    ///
    /// Also invalidates the current session delegate so any lingering
    /// SDK callbacks from the old client cannot write stale tokens.
    func clearSession() {
        sessionDelegate.invalidate()
        KeychainService.delete()
        // Everything, not only the stores: the search index holds decrypted
        // text, and the next account must not inherit it, nor the key.
        Self.resetAllLocalData()
        KeychainService.deleteStoreKey()
        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "Session cleared"
        )
    }

    // MARK: - Private

    private func saveSession(_ session: Session) {
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData
        )
        if let encoded = try? JSONEncoder().encode(stored) {
            KeychainService.save(encoded)
            activityLog?.log(
                category: .auth, severity: .debug, source: "AuthenticationService",
                summary: "Session saved to keychain"
            )
        } else {
            activityLog?.log(
                category: .auth, severity: .warning, source: "AuthenticationService",
                summary: "Failed to encode session for keychain"
            )
        }
    }
}

// MARK: - OIDC Session Delegate

final class KeychainSessionDelegate: ClientSessionDelegate, @unchecked Sendable {
    /// Guards against stale callbacks from a previous SDK client.
    ///
    /// When `AuthenticationService` creates a new client (e.g. on re-login),
    /// it invalidates the previous delegate so that any lingering token-refresh
    /// callbacks from the old Rust SDK client are silently dropped instead of
    /// overwriting the new session's tokens in the keychain.
    ///
    /// A mutex, held across the check *and* the write: the SDK calls in on its
    /// own threads while ``invalidate()`` runs on the main actor. With a plain
    /// flag, a refresh from the old client could pass the check, then land
    /// after the new session was saved — storing revoked tokens, and signing
    /// the user out on the next launch.
    private let validity = Mutex(true)

    /// Where refreshed sessions are written. The Keychain in the app; a probe
    /// in tests, which must never touch the live session.
    private let write: @Sendable (Data) -> Void

    init(write: @escaping @Sendable (Data) -> Void = { _ = KeychainService.save($0) }) {
        self.write = write
    }

    /// Activity log reference for reporting keychain operations.
    ///
    /// Set by ``AuthenticationService/makeBuilder()`` when creating a new delegate.
    /// Because this class is `nonisolated`, all activity log calls dispatch
    /// to `@MainActor`.
    weak var activityLog: ActivityLog?

    /// Marks this delegate as invalid so all future callbacks are ignored.
    func invalidate() {
        validity.withLock { $0 = false }
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard validity.withLock({ $0 }) else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .debug, source: "KeychainSessionDelegate",
                    summary: "Stale session retrieve callback ignored"
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        guard let data = KeychainService.load() else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .warning, source: "KeychainSessionDelegate",
                    summary: "Keychain load returned no data"
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .error, source: "KeychainSessionDelegate",
                    summary: "Failed to decode session from keychain"
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        guard stored.userId == userId else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .error, source: "KeychainSessionDelegate",
                    summary: "Keychain userId mismatch",
                    metadata: ["expected": userId, "actual": stored.userId]
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        return Session(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userId: stored.userId,
            deviceId: stored.deviceId,
            homeserverUrl: stored.homeserverUrl,
            oauthData: stored.oauthData,
            slidingSyncVersion: .native
        )
    }

    func saveSessionInKeychain(session: Session) {
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData
        )
        if let data = try? JSONEncoder().encode(stored) {
            // Checked and written under one lock, so invalidate() cannot slip
            // between them.
            let write = self.write
            let saved = validity.withLock { isValid -> Bool in
                guard isValid else { return false }
                write(data)
                return true
            }
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .debug, source: "KeychainSessionDelegate",
                    summary: saved ? "Token refresh saved to keychain" : "Stale session save callback ignored"
                )
            }
        } else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .error, source: "KeychainSessionDelegate",
                    summary: "Failed to encode refreshed session"
                )
            }
        }
    }
}

enum KeychainSessionError: Error {
    case sessionNotFound
}
