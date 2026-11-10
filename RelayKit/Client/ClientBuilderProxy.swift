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

// ClientBuilderProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A builder for constructing a ``ClientProxy`` with the desired configuration.
///
/// Wraps the Matrix SDK `ClientBuilder` with a Swift-friendly fluent API.
/// Call configuration methods to set up the store path, homeserver, proxy,
/// and encryption settings, then call ``build()`` to create the client.
///
/// ```swift
/// let client = try await ClientBuilderProxy()
///     .homeserverUrl("https://matrix.org")
///     .sessionPaths(dataPath: dataDir, cachePath: cacheDir)
///     .build()
/// ```
///
/// ## Topics
///
/// ### Configuration
/// - ``homeserverUrl(_:)``
/// - ``serverName(_:)``
/// - ``serverNameOrHomeserverUrl(_:)``
/// - ``sessionPaths(dataPath:cachePath:)``
/// - ``username(_:)``
///
/// ### Building
/// - ``build()``
public final class ClientBuilderProxy: @unchecked Sendable {
    private var builder: ClientBuilder

    // MARK: - Configuration Record

    // What this builder was configured with, in non-sensitive form. Exists so
    // tests can assert that the security posture actually reaches the SDK
    // builder, instead of trusting that a one-line call still sits somewhere
    // in a service. Facts only, never material: a Bool for the store key, not
    // the key.

    /// The room-key recipient strategy handed to the SDK, if any.
    public private(set) var configuredRecipientStrategy: CollectStrategy?

    /// Whether the SQLite store was opened with key material.
    public private(set) var configuredStoreEncryption = false

    /// Whether the local search index was enabled (always with a password).
    public private(set) var configuredSearchIndex = false

    /// The User-Agent handed to the SDK, if any.
    public private(set) var configuredUserAgent: String?

    /// Creates a new client builder.
    public init() {
        self.builder = ClientBuilder()
    }

    /// Sets the homeserver URL.
    ///
    /// - Parameter url: The homeserver URL string.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func homeserverUrl(_ url: String) -> ClientBuilderProxy {
        builder = builder.homeserverUrl(url: url)
        return self
    }

    /// Sets the server name for well-known lookup.
    ///
    /// - Parameter serverName: The server name (e.g. `matrix.org`).
    /// - Returns: This builder for chaining.
    @discardableResult
    public func serverName(_ serverName: String) -> ClientBuilderProxy {
        builder = builder.serverName(serverName: serverName)
        return self
    }

    /// Sets either a server name or homeserver URL.
    ///
    /// - Parameter serverNameOrUrl: The server name or URL.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func serverNameOrHomeserverUrl(_ serverNameOrUrl: String) -> ClientBuilderProxy {
        builder = builder.serverNameOrHomeserverUrl(serverNameOrUrl: serverNameOrUrl)
        return self
    }

    /// Sets the session store paths.
    ///
    /// - Parameters:
    ///   - dataPath: The path for persistent data.
    ///   - cachePath: The path for cache data.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func sessionPaths(dataPath: String, cachePath: String) -> ClientBuilderProxy {
        builder = builder.sessionPaths(dataPath: dataPath, cachePath: cachePath)
        return self
    }

    /// Sets the username for the session.
    ///
    /// - Parameter username: The Matrix username.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func username(_ username: String) -> ClientBuilderProxy {
        builder = builder.username(username: username)
        return self
    }

    /// Sets the user agent string.
    ///
    /// - Parameter userAgent: The user agent string.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func userAgent(_ userAgent: String) -> ClientBuilderProxy {
        configuredUserAgent = userAgent
        builder = builder.userAgent(userAgent: userAgent)
        return self
    }

    /// Sets an HTTP proxy URL.
    ///
    /// - Parameter url: The proxy URL.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func proxy(_ url: String) -> ClientBuilderProxy {
        builder = builder.proxy(url: url)
        return self
    }

    /// Uses an in-memory store instead of SQLite.
    ///
    /// - Returns: This builder for chaining.
    @discardableResult
    public func inMemoryStore() -> ClientBuilderProxy {
        builder = builder.inMemoryStore()
        return self
    }

    /// Disables SSL certificate verification.
    ///
    /// - Warning: Only use this for development/testing.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func disableSslVerification() -> ClientBuilderProxy {
        builder = builder.disableSslVerification()
        return self
    }

    /// Enables automatic cross-signing setup.
    ///
    /// - Parameter enabled: Whether to auto-enable cross-signing.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func autoEnableCrossSigning(_ enabled: Bool) -> ClientBuilderProxy {
        builder = builder.autoEnableCrossSigning(autoEnableCrossSigning: enabled)
        return self
    }

    /// Enables automatic backup setup.
    ///
    /// - Parameter enabled: Whether to auto-enable backups.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func autoEnableBackups(_ enabled: Bool) -> ClientBuilderProxy {
        builder = builder.autoEnableBackups(autoEnableBackups: enabled)
        return self
    }

    /// Turns on the SDK's thread support: thread timelines that follow sync,
    /// and thread summaries that update on the root. Without it a thread
    /// showed what it held when opened and nothing after.
    ///
    /// - Parameter subscriptions: Whether to also use MSC4306 thread
    ///   subscriptions, which servers may not support yet.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func threadsEnabled(_ enabled: Bool, subscriptions: Bool) -> ClientBuilderProxy {
        builder = builder.threadsEnabled(enabled: enabled, threadSubscriptions: subscriptions)
        return self
    }

    /// Uses an encrypted SQLite store at the given paths.
    ///
    /// Supersedes ``sessionPaths(dataPath:cachePath:)`` — the store builder
    /// carries the paths itself, so call one or the other, not both.
    ///
    /// The SDK's stores hold the Olm account, Megolm sessions, device keys,
    /// cached events and cached media, all encrypted at rest with `key`.
    ///
    /// The key is not optional. The SDK would accept `nil` and store everything
    /// in plaintext; this wrapper makes that impossible to ask for, so no
    /// future call site can reintroduce it by passing along a failed lookup.
    ///
    /// - Parameters:
    ///   - dataPath: Directory for persistent state.
    ///   - cachePath: Directory for regenerable cache data.
    ///   - key: 256-bit key material.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func encryptedSqliteStore(dataPath: String, cachePath: String, key: Data) -> ClientBuilderProxy {
        configuredStoreEncryption = true
        let store = SqliteStoreBuilder(dataPath: dataPath, cachePath: cachePath)
            .key(key: key)
        builder = builder.sqliteStore(config: store)
        return self
    }

    /// Enables the local message search index.
    ///
    /// Without this the SDK indexes nothing and every search returns an empty
    /// iterator — which is what Plic did before, while appearing to search.
    ///
    /// The index holds the **plaintext** of decrypted messages. Storing it
    /// without a password would undo end-to-end encryption on disk: anything
    /// said in an encrypted room would sit readable in a file next to the
    /// encrypted store. The password is therefore not optional here even though
    /// the SDK allows it to be.
    ///
    /// Only messages seen after this is switched on get indexed, so search is
    /// blind to history the SDK has already processed.
    ///
    /// - Parameters:
    ///   - path: Directory for the index. Must be unique per session.
    ///   - password: Key material used to encrypt the index at rest.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func searchIndexStore(path: String, password: String) -> ClientBuilderProxy {
        configuredSearchIndex = true
        builder = builder.withSearchIndexStore(path: path, password: password)
        return self
    }

    /// Chooses which of a recipient's devices may receive room keys.
    ///
    /// Plic passes ``CollectStrategy/identityBasedStrategy``, the strategy
    /// [MSC4153](https://github.com/matrix-org/matrix-doc/pull/4153) recommends
    /// and the one Element runs in its "exclude insecure devices" mode: keys go
    /// only to devices signed by their owner's published identity. A user who
    /// has never set up cross-signing receives nothing.
    ///
    /// Leaving this unset falls back to the SDK default, which still shares
    /// with unsigned devices — so this call is what makes the guarantee real.
    ///
    /// - Parameter strategy: The device-collection strategy.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func roomKeyRecipientStrategy(_ strategy: CollectStrategy) -> ClientBuilderProxy {
        configuredRecipientStrategy = strategy
        builder = builder.roomKeyRecipientStrategy(strategy: strategy)
        return self
    }

    /// Sets the sliding sync version builder.
    ///
    /// - Parameter versionBuilder: The sliding sync version configuration.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func slidingSyncVersionBuilder(_ versionBuilder: SlidingSyncVersionBuilder) -> ClientBuilderProxy {
        builder = builder.slidingSyncVersionBuilder(versionBuilder: versionBuilder)
        return self
    }

    /// Sets the request configuration.
    ///
    /// - Parameter config: The request configuration.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func requestConfig(_ config: RequestConfig) -> ClientBuilderProxy {
        builder = builder.requestConfig(config: config)
        return self
    }

    /// Sets the session delegate for keychain operations.
    ///
    /// - Parameter delegate: The session delegate.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func setSessionDelegate(_ delegate: ClientSessionDelegate) -> ClientBuilderProxy {
        builder = builder.setSessionDelegate(sessionDelegate: delegate)
        return self
    }

    /// Builds the client with the configured options and wraps it in a ``ClientProxy``.
    ///
    /// Use this when the client is already authenticated (e.g. after login or session
    /// restore). The proxy immediately reads `userId` and `deviceId` from the client.
    ///
    /// - Returns: A configured ``ClientProxy``.
    /// - Throws: `ClientBuildError` if the build fails.
    public func build() async throws -> ClientProxy {
        let client = try await builder.build()
        return try ClientProxy(client: client)
    }

    /// Builds a raw SDK `Client` without wrapping it in a ``ClientProxy``.
    ///
    /// Use this when the client needs to be authenticated before wrapping (e.g.
    /// session restore or login), since ``ClientProxy`` requires an authenticated
    /// client to read `userId` and `deviceId` at initialization.
    ///
    /// After authenticating the raw client, wrap it with ``ClientProxy/init(client:)``.
    ///
    /// - Returns: The raw SDK `Client`.
    /// - Throws: `ClientBuildError` if the build fails.
    public func buildClient() async throws -> Client {
        try await builder.build()
    }
}
