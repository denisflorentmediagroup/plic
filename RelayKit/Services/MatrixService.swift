// swiftlint:disable file_length
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

import AppKit
import Foundation
import RelayInterface
import Synchronization

/// The concrete implementation of ``MatrixServiceProtocol`` backed by the Matrix Rust SDK.
///
/// ``MatrixService`` acts as a thin facade that coordinates several focused sub-services:
/// - ``AuthenticationService`` — login, session restore, OAuth/OIDC
/// - ``SyncManager`` — sync lifecycle and state observation
/// - ``RoomListManager`` — room list polling and sorting
/// - ``MediaService`` — avatar and media caching/fetching
///
/// This class is `@Observable` and `@MainActor`-isolated so that SwiftUI views can bind
/// directly to its published state.
@Observable
// swiftlint:disable:next type_body_length
public final class MatrixService: MatrixServiceProtocol {

    public private(set) var authState: AuthState = .unknown
    public var syncState: SyncState { syncManager.syncState }
    public var rooms: [RelayInterface.RoomSummary] { roomListManager.rooms }
    public var spaces: [RelayInterface.RoomSummary] { spaceListManager.spaces }

    public var isSyncing: Bool { syncState == .syncing || syncState == .running }
    public var hasLoadedRooms: Bool { roomListManager.hasLoadedRooms }
    public var isNetworkConnected: Bool { networkMonitor.isConnected }

    public private(set) var isSessionVerified: Bool = false
    public private(set) var hasCheckedVerificationState: Bool = false
    public var pendingVerificationRequest: IncomingVerificationRequest?
    public var shouldPresentVerificationSheet: Bool = false
    public var pendingDeepLink: MatrixURI?
    public let errorReporter = ErrorReporter()

    /// Callback invoked when a room has new notification-worthy unread activity.
    ///
    /// The app layer sets this to post system notifications. The callback
    /// provides the room name, room ID, message body, and whether it's a mention.
    public var onNotificationEvent: ((RoomNotificationEvent) -> Void)? {
        didSet {
            let externalHandler = onNotificationEvent
            roomListManager.onNotificationEvent = { [weak self] event in
                externalHandler?(event)
                // Donate an incoming message intent for share sheet suggestions.
                guard let self else { return }
                if let roomSummary = self.rooms.first(where: { $0.id == event.roomId }) {
                    self.intentDonation.donateIncomingMessage(
                        roomSummary: roomSummary,
                        senderName: event.messageAuthor
                    )
                }
            }
        }
    }

    /// Whether conversations may be suggested to macOS for the share sheet.
    ///
    /// The app turns this off while notifications are set to reveal nothing:
    /// the suggestions would hand macOS the same names. Turning it off also
    /// withdraws the suggestions already made.
    @ObservationIgnored public var allowsShareSuggestions = true {
        didSet {
            let allowed = allowsShareSuggestions
            Task { await intentDonation.setEnabled(allowed) }
        }
    }

    // MARK: - Private State

    private var client: ClientProxy?
    private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var timelineViewModels: [String: TimelineViewModel] = [:]

    /// The account's default notification level for direct chats, as the
    /// server has it. Rooms without a rule of their own follow it.
    public private(set) var defaultDirectNotificationMode: DefaultNotificationMode = .allMessages
    /// The same for group rooms.
    public private(set) var defaultGroupNotificationMode: DefaultNotificationMode = .mentionsAndKeywordsOnly
    /// Room IDs ordered by most-recent access (last element = most recent).
    /// Used to implement LRU eviction for ``timelineViewModels``.
    @ObservationIgnored private var timelineAccessOrder: [String] = []
    /// Maximum number of ``TimelineViewModel`` instances to keep cached.
    /// When exceeded, the least-recently-used entry is evicted.
    private let timelineCacheCapacity = 10
    private var cachedNotificationKeywords: [String] = []
    private var verificationController: SessionVerificationControllerProxy?
    private var verificationObservationTask: Task<Void, Never>?
    private var verificationStateTask: Task<Void, Never>?


    // MARK: - Sub-Services

    private let networkMonitor = NetworkMonitor()
    private let auth: AuthenticationService
    private let syncManager: SyncManager
    private let roomListManager = RoomListManager()
    private let spaceListManager = SpaceListManager()
    private let media = MediaService()
    private let intentDonation = IntentDonationService()
    private let _activityLog = ActivityLog()

    public var activityLog: any ActivityLogProtocol { _activityLog }

    /// Creates a new ``MatrixService``. Call ``restoreSession()`` after initialization to
    /// attempt automatic sign-in from a previously saved keychain session.
    public init() {
        auth = AuthenticationService(networkMonitor: networkMonitor)
        auth.activityLog = _activityLog
        syncManager = SyncManager(networkMonitor: networkMonitor, activityLog: _activityLog)
        networkMonitor.activityLog = _activityLog
        roomListManager.activityLog = _activityLog
    }

    // MARK: - Session Restore

    public func restoreSession() async {
        // Under a test run, never touch the developer's real session. The test
        // bundle executes inside this app as its host, so without this guard
        // every `xcodebuild test` restored the session and started a second
        // sync alongside the developer's running copy. OIDC refresh tokens are
        // single-use: two instances rotating the same token look like replay to
        // the server, which revokes the session — the developer found
        // themselves logged out and blamed whatever else shipped that day.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            authState = .loggedOut
            return
        }

        // Start the network monitor early so `AuthenticationService` can
        // see the current connectivity state and so the SyncManager can
        // wake us up when the network returns after an offline restore.
        networkMonitor.start()

        switch await auth.restoreSession() {
        case .noSavedSession:
            authState = .loggedOut
            _activityLog.log(
                category: .auth, severity: .info, source: "MatrixService",
                summary: "No saved session found"
            )
            // Signed out, so nothing about any account's rooms should remain
            // for the share sheet, whichever way the last session ended.
            await forgetShareTargets()

        case .restored(let restoredClient, let userId):
            client = restoredClient
            await restoredClient.loadProfile()
            authState = .loggedIn(userId: userId)
            _activityLog.log(
                category: .auth, severity: .info, source: "MatrixService",
                summary: "Session restored",
                metadata: ["userId": userId]
            )

        case .offlineWithSavedSession(let userId, _):
            authState = .loggedIn(userId: userId)
            _activityLog.log(
                category: .auth, severity: .warning, source: "MatrixService",
                summary: "Offline with saved session — deferring sync",
                metadata: ["userId": userId]
            )
            syncManager.onPendingOnlineRestore = { [weak self] in
                await self?.retryPendingOnlineRestore()
            }
            syncManager.enterPendingOnlineRestore()

        case .localDataUnreadable(let userId):
            authState = .localDataUnreadable(userId: userId)
            _activityLog.log(
                category: .auth, severity: .error, source: "MatrixService",
                summary: "Local data cannot be decrypted — store key missing",
                metadata: ["userId": userId]
            )

        case .keychainUnavailable:
            authState = .keychainUnavailable

        case .failed(let error):
            authState = .error(error.localizedDescription)
            _activityLog.log(
                category: .auth, severity: .error, source: "MatrixService",
                summary: "Session restore failed",
                detail: error.localizedDescription
            )
        }
    }

    /// Called by ``SyncManager`` when it detects a network reconnect while
    /// we're still in the offline-restored state. Re-runs
    /// ``AuthenticationService/restoreSession()`` and, on success, hands
    /// the freshly built ``ClientProxy`` to the sync pipeline.
    private func retryPendingOnlineRestore() async {
        switch await auth.restoreSession() {
        case .restored(let restoredClient, let userId):
            client = restoredClient
            await restoredClient.loadProfile()
            authState = .loggedIn(userId: userId)
            // Tear down the placeholder pending-restore handler before
            // performSync wires up the real onSyncServiceRestarted hook.
            syncManager.onPendingOnlineRestore = nil
            await performSync()

        case .offlineWithSavedSession:
            // Still can't reach the homeserver — stay offline. The
            // network monitor will fire again when connectivity flips,
            // and SyncManager will call us back.
            break

        case .localDataUnreadable(let userId):
            authState = .localDataUnreadable(userId: userId)

        case .keychainUnavailable:
            authState = .keychainUnavailable

        case .failed(let error):
            authState = .error(error.localizedDescription)

        case .noSavedSession:
            // Keychain went away under us mid-restore. Bounce to login.
            authState = .loggedOut
        }
    }

    // MARK: - Login

    public func login(username: String, password: String, homeserver: String) async {
        authState = .loggingIn
        do {
            let (newClient, userId) = try await auth.login(
                username: username, password: password, homeserver: homeserver
            )
            client = newClient
            await newClient.loadProfile()
            authState = .loggedIn(userId: userId)
        } catch is KeychainUnavailableError {
            authState = .keychainUnavailable
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - OAuth Login

    public func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws {
        authState = .loggingIn
        do {
            let (newClient, userId) = try await auth.startOAuthLogin(
                homeserver: homeserver,
                openURL: openURL
            )
            client = newClient
            await newClient.loadProfile()
            authState = .loggedIn(userId: userId)
        } catch is KeychainUnavailableError {
            authState = .keychainUnavailable
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - Logout

    public func logout() async {
        // Set authState first so SwiftUI immediately switches to LoginView.
        // This prevents ContentView from seeing syncState == .idle (after
        // syncManager.stop()) and re-triggering startSyncIfNeeded() on the
        // old client while logout is still tearing down.
        authState = .loggedOut

        try? await client?.logout()
        auth.clearSession()
        await teardown()
        await forgetShareTargets()
        // Room and user names from this session have no place in the next.
        _activityLog.clear()
    }

    /// Discards unreadable local data and returns to the login screen.
    ///
    /// Used only from ``LocalDataUnreadableView``. There is no client to log
    /// out of — restore failed before one was built — so this deletes the
    /// stores, drops the saved session, and lets the user sign in fresh. The
    /// search index goes too: it holds decrypted message text under the same
    /// missing key.
    public func signOutAndResetLocalData() async {
        authState = .loggedOut
        await teardown()
        AuthenticationService.resetAllLocalData()
        auth.clearSession()
        await forgetShareTargets()
    }

    /// Removes what the share sheet and the share extension know about this
    /// account's rooms: the suggestions donated to macOS, and the room list
    /// and pending shares in the app group. Both live outside the encrypted
    /// stores and would otherwise outlast the session.
    private func forgetShareTargets() async {
        roomCacheWriteTask?.cancel()
        roomCacheWriteTask = nil
        shareAvatarData = [:]
        lastWrittenShareableRooms = nil
        PendingShareStore.removeAll()
        await intentDonation.removeAllDonations()
    }

    // MARK: - Clear Local Data

    public func clearLocalData() async {
        await teardown()

        // Delete only the rebuildable cache (sync state, timeline events).
        // The data directory (crypto store, device identity) is preserved
        // so the session remains verified after restart.
        AuthenticationService.resetCacheData()

        // Restore the session from the keychain, rebuilding the client
        // with the existing crypto store, then restart sync.
        await restoreSession()
        startSyncIfNeeded()
    }

    /// Cancels all background tasks, stops sync, and resets all in-memory state.
    private func teardown() async {
        syncTask?.cancel()
        syncTask = nil
        verificationObservationTask?.cancel()
        verificationObservationTask = nil
        verificationStateTask?.cancel()
        verificationStateTask = nil

        networkMonitor.stop()
        await syncManager.stop()

        client = nil
        verificationController = nil
        isSessionVerified = false
        hasCheckedVerificationState = false
        isVerificationFlowActive = false
        pendingVerificationRequest = nil
        shouldPresentVerificationSheet = false
        roomListManager.reset()
        spaceListManager.reset()
        media.reset()
        discardTimelines(ids: Array(timelineViewModels.keys))
        cachedNotificationKeywords = []
        pendingDeepLink = nil
    }

    // MARK: - Sync

    public func startSyncIfNeeded() {
        guard syncManager.syncState == .idle else { return }
        syncTask = Task { await performSync() }
    }

    private func performSync() async {
        guard let client = currentClient else { return }

        _activityLog.log(
            category: .sync, severity: .info, source: "MatrixService",
            summary: "Starting sync pipeline"
        )

        do {
            // Start network monitoring before sync so the SyncManager can
            // react to connectivity changes from the very beginning.
            networkMonitor.start()

            // Wire the auth failure callback so SyncManager can notify us
            // when a rebuild fails due to an expired refresh token (e.g.
            // after an extended sleep). We report the error so the user
            // sees an explanation, then log out cleanly so they return to
            // the login screen.
            syncManager.onAuthenticationFailure = { [weak self] in
                guard let self else { return }
                self._activityLog.log(
                    category: .auth, severity: .error, source: "MatrixService",
                    summary: "Session invalidated — logging out"
                )
                self.errorReporter.report(.sessionExpired)
                await self.logout()
            }

            // Wire the restart callback so SyncManager can notify us when
            // the sync service is rebuilt after a connectivity restoration.
            // RoomListManager re-subscribes to the new service's room list,
            // preserving existing room state and receiving incremental diffs.
            syncManager.onSyncServiceRestarted = { [weak self] syncService in
                guard let self else { return }
                try await self.roomListManager.restart(syncService: syncService)

                // Cycle active timelines through suspend/resume so they
                // rebuild their SDK Timeline objects under the new sync
                // service. Without this, timelines created before the
                // reconnect hold stale references and never receive new
                // events.
                var activeRoomIds: [String] = []
                for (roomId, vm) in self.timelineViewModels where !vm.isSuspended {
                    vm.suspend()
                    await vm.resume()
                    activeRoomIds.append(roomId)
                }

                // Re-subscribe active rooms to the new RoomListService so
                // the sliding sync proxy delivers full timeline events for
                // them. The previous subscriptions were tied to the old
                // sync service and are no longer valid.
                if !activeRoomIds.isEmpty {
                    for roomId in activeRoomIds {
                        self.subscribeToRoom(roomId)
                    }
                }
            }

            try await syncManager.startSync(client: client)
            _activityLog.log(
                category: .sync, severity: .info, source: "MatrixService",
                summary: "Sync manager started, starting client observation"
            )
            try await client.startObserving()
            if let sdkController = try? await client.getSessionVerificationController() {
                verificationController = SessionVerificationControllerProxy(controller: sdkController)
                observeVerificationController()
            }
            observeVerificationState(client: client)
            if let syncService = syncManager.syncService {
                try await roomListManager.start(syncService: syncService)
                _activityLog.log(
                    category: .sync, severity: .info, source: "MatrixService",
                    summary: "Room list manager started"
                )
            }
            observeSpaceDescendants()
            await spaceListManager.start(client: client)
            _activityLog.log(
                category: .sync, severity: .info, source: "MatrixService",
                summary: "Space list manager started — sync pipeline complete"
            )
            cachedNotificationKeywords = (try? await getNotificationKeywords()) ?? []
            roomListManager.notificationKeywords = cachedNotificationKeywords
            await refreshDefaultNotificationModes()
            roomListManager.currentUserId = client.userID
        } catch is CancellationError {
            // Logout cancelled the sync — don't overwrite state
        } catch {
            _activityLog.log(
                category: .sync, severity: .error, source: "MatrixService",
                summary: "Sync failed", detail: error.localizedDescription
            )
        }
    }

    /// Whether a verification flow is currently being managed by a view model.
    ///
    /// When `true`, the `observeVerificationController` observer should not surface
    /// incoming requests as `pendingVerificationRequest` — the active view model
    /// handles them directly.
    private var isVerificationFlowActive = false

    /// Observes the verification controller's flow state for incoming verification requests.
    ///
    /// Only surfaces requests when no verification view model is currently active.
    /// When the user has the verification sheet open (outgoing or incoming), the
    /// ``SessionVerificationViewModel`` handles flow state transitions directly.
    private func observeVerificationController() {
        verificationObservationTask?.cancel()
        verificationObservationTask = Task { [weak self] in
            guard let self, let controller = verificationController else { return }
            while !Task.isCancelled {
                let flowState = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = controller.flowState
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume(returning: controller.flowState)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                if case .receivedRequest(let details) = flowState, !isVerificationFlowActive {
                    _activityLog.log(
                        category: .auth, severity: .info, source: "MatrixService",
                        summary: "Incoming verification request from device \(details.deviceId)"
                    )
                    pendingVerificationRequest = IncomingVerificationRequest(
                        deviceId: String(details.deviceId),
                        senderId: details.senderProfile.userId,
                        flowId: details.flowId
                    )
                }
            }
        }
    }

    /// Observes the SDK encryption verification state and keeps `isSessionVerified` in sync.
    private func observeVerificationState(client: ClientProxy) {
        verificationStateTask?.cancel()
        isSessionVerified = client.encryption().verificationState() == .verified
        hasCheckedVerificationState = true
        verificationStateTask = Task { [weak self] in
            let encryption = client.encryption()
            let listener = SDKListener<MatrixRustSDK.VerificationState> { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.isSessionVerified = state == .verified
                }
            }
            let handle = encryption.verificationStateListener(listener: listener)
            // Keep the handle alive until the task is cancelled.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
            handle.cancel()
        }
    }

    // MARK: - Space Descendants

    /// Observes changes to the space-to-room mapping and propagates `parentSpaceIds`
    /// to each room's ``RoomSummary``.
    ///
    /// When the ``SpaceListManager`` updates its ``SpaceListManager/spaceDescendants``
    /// mapping (due to rooms being added/removed from spaces), this method iterates
    /// through all rooms and updates their `parentSpaceIds` accordingly.
    private func observeSpaceDescendants() {
        spaceListManager.onDescendantsChanged = { [weak self] in
            self?.applySpaceDescendantsToRooms()
        }
        roomListManager.onRoomsRebuilt = { [weak self] in
            self?.applySpaceDescendantsToRooms()
            self?.scheduleRoomCacheWrite()
        }
    }

    /// Updates each room and space summary's `parentSpaceIds` from the current space descendants map.
    private func applySpaceDescendantsToRooms() {
        let descendants = spaceListManager.spaceDescendants
        updateParentSpaceIds(for: roomListManager.rooms, from: descendants)
        updateParentSpaceIds(for: spaceListManager.spaces, from: descendants)
    }

    /// Sets `parentSpaceIds` on each summary by scanning the descendants map.
    private func updateParentSpaceIds(
        for summaries: [RelayInterface.RoomSummary],
        from descendants: [String: Set<String>]
    ) {
        for summary in summaries {
            var newParents = Set<String>()
            for (spaceId, childIds) in descendants where childIds.contains(summary.id) {
                newParents.insert(spaceId)
            }
            if summary.parentSpaceIds != newParents {
                summary.parentSpaceIds = newParents
            }
        }
    }

    // MARK: - Room Cache for Share Extension

    @ObservationIgnored private var roomCacheWriteTask: Task<Void, Never>?
    /// Avatar bytes already read for the share cache, by `mxc://` URL. The
    /// room list rebuilds on every message in any room, and each rebuild
    /// used to read every avatar from disk again.
    @ObservationIgnored private var shareAvatarData: [String: Data?] = [:]
    /// What was last written, so an identical snapshot is not written twice.
    @ObservationIgnored private var lastWrittenShareableRooms: [RelayInterface.ShareableRoom]?

    /// Writes the room list to the app group container after a short debounce.
    ///
    /// Called after each room list rebuild so the share extension always has a
    /// recent snapshot of available rooms. Avatar data is read from the
    /// on-disk media cache (no network requests are made).
    private func scheduleRoomCacheWrite() {
        roomCacheWriteTask?.cancel()
        roomCacheWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }

            let joinedRooms = self.rooms.filter { !$0.isSpace && $0.membership == .joined }
            var shareableRooms: [RelayInterface.ShareableRoom] = []
            shareableRooms.reserveCapacity(joinedRooms.count)

            for room in joinedRooms {
                guard !Task.isCancelled else { return }
                var avatarData: Data?
                if let mxcURL = room.avatarURL {
                    if let known = self.shareAvatarData[mxcURL] {
                        avatarData = known
                    } else {
                        avatarData = await self.media.cachedAvatarData(mxcURL: mxcURL, size: 48)
                        if avatarData != nil { self.shareAvatarData[mxcURL] = avatarData }
                    }
                }
                shareableRooms.append(RelayInterface.ShareableRoom(
                    id: room.id,
                    name: room.name,
                    isDirect: room.isDirect,
                    avatarData: avatarData,
                    lastActivityTimestamp: room.lastMessageTimestamp
                ))
            }

            guard shareableRooms != self.lastWrittenShareableRooms else { return }
            self.lastWrittenShareableRooms = shareableRooms
            PendingShareStore.writeRoomCache(shareableRooms)
        }
    }

    // MARK: - Room Access

    /// Looks up a joined room by its Matrix room identifier.
    ///
    /// - Parameter id: The Matrix room ID.
    /// - Returns: The SDK `Room` object, or `nil` if not found.
    func room(id: String) -> Room? {
        roomListManager.sdkRoom(id: id) ?? client?.rooms().first { $0.id() == id }
    }

    /// Returns the client proxy, throwing ``RelayError/notLoggedIn`` if nil.
    ///
    /// Use in methods whose API contract already throws.
    private func requireClient() throws -> ClientProxy {
        guard let client else { throw RelayError.notLoggedIn }
        return client
    }

    /// Returns the client proxy, or `nil` with a logged warning if not available.
    ///
    /// Use in non-throwing methods where a nil client indicates an unexpected state.
    private var currentClient: ClientProxy? {
        guard let client else {
            _activityLog.log(
                category: .auth, severity: .warning, source: "MatrixService",
                summary: "Operation attempted without an active client"
            )
            return nil
        }
        return client
    }

    public func userId() -> String? {
        client?.userID
    }

    public func userDisplayName() async -> String? {
        guard let client = currentClient else { return nil }
        return client.displayName
    }

    public func setDisplayName(_ name: String) async throws {
        guard let client = currentClient else { return }
        try await client.setDisplayName(name)
    }

    public func userAvatarURL() async -> String? {
        guard let client = currentClient else { return nil }
        return client.avatarURL?.absoluteString
    }

    public func uploadUserAvatar(mimeType: String, data: Data) async throws {
        guard let client = currentClient else { return }
        try await client.uploadAvatar(mimeType: mimeType, data: data)
    }

    public func removeUserAvatar() async throws {
        guard let client = currentClient else { return }
        try await client.removeAvatar()
    }

    public func homeserverAddress() -> String? {
        client?.homeserver
    }

    public func deviceId() -> String? {
        client?.deviceID
    }

    public func makeTimelineViewModel(roomId: String) -> (any TimelineViewModelProtocol)? {
        if let cached = timelineViewModels[roomId] {
            touchTimelineAccessOrder(roomId)
            subscribeToRoom(roomId)
            return cached
        }
        guard let room = room(id: roomId) else { return nil }
        let summary = rooms.first(where: { $0.id == roomId })
        let unreadCount = summary?.lastKnownUnreadCount ?? summary?.notificationCount ?? 0
        // swiftlint:disable:next identifier_name
        let vm = TimelineViewModel(
            room: room, currentUserId: userId(),
            unreadCount: Int(unreadCount),
            notificationKeywords: cachedNotificationKeywords,
            errorReporter: errorReporter,
            activityLog: _activityLog,
            encryption: client?.encryption()
        )
        timelineViewModels[roomId] = vm
        touchTimelineAccessOrder(roomId)
        evictStaleTimelines()

        subscribeToRoom(roomId)

        return vm
    }

    public func makeThreadTimelineViewModel(roomId: String) -> (any TimelineViewModelProtocol)? {
        guard let room = room(id: roomId) else { return nil }
        return TimelineViewModel(
            room: room,
            currentUserId: userId(),
            errorReporter: errorReporter,
            activityLog: _activityLog,
            encryption: client?.encryption()
        )
    }

    /// Suspends the timeline view model for a room to free background resources.
    ///
    /// The cached ``TimelineViewModel`` is kept so previously loaded messages are
    /// available for instant display, but its SDK observation tasks and handles
    /// are released.
    public func suspendTimeline(roomId: String) {
        guard let vm = timelineViewModels[roomId], !vm.isSuspended else { return }
        vm.suspend()
        // The SDK's Timeline object is released by suspend(), allowing the
        // Rust runtime to drop its internal resources.  There is no explicit
        // unsubscribe API on RoomListService -- the server-side sliding sync
        // window is managed automatically by the SDK.
        _activityLog.log(
            category: .timeline, severity: .info, source: "MatrixService",
            summary: "Suspended timeline VM", roomId: roomId
        )
    }

    /// Resumes a previously suspended timeline view model, re-establishing live
    /// observation with the SDK.
    ///
    /// This also re-subscribes to the room in sliding sync so the server
    /// prioritises updates for it again.
    public func resumeTimeline(roomId: String) async {
        await timelineViewModels[roomId]?.resume()
        subscribeToRoom(roomId)
    }

    /// Subscribes to a room at a higher detail level in the sliding sync.
    ///
    /// This tells the sliding sync proxy to prioritise this room for
    /// full timeline event delivery (including `m.room.pinned_events`
    /// and other state events). Must be called every time a room becomes
    /// active — the subscription is tied to the current ``RoomListService``
    /// and is lost when the sync service is rebuilt.
    private func subscribeToRoom(_ roomId: String) {
        guard let rls = roomListManager.roomListService else { return }
        Task {
            try? await rls.subscribeToRooms(roomIds: [roomId])
        }
    }

    /// Moves `roomId` to the end of the access-order list (most recently used).
    private func touchTimelineAccessOrder(_ roomId: String) {
        timelineAccessOrder.removeAll { $0 == roomId }
        timelineAccessOrder.append(roomId)
    }

    /// Drops timeline view models for good: suspended first, so their
    /// observation tasks and SDK handles end with them. Removing one from
    /// the cache while it still observed left its task, its listener and the
    /// SDK timeline alive — after sign-out, after leaving a room.
    private func discardTimelines(ids: [String]) {
        for id in ids {
            if let vm = timelineViewModels.removeValue(forKey: id), !vm.isSuspended {
                vm.suspend()
            }
            timelineAccessOrder.removeAll { $0 == id }
        }
    }

    /// Evicts the least-recently-used timeline view models when the cache
    /// exceeds ``timelineCacheCapacity``. Suspended VMs are evicted first;
    /// if all are active, the oldest is suspended then evicted.
    private func evictStaleTimelines() {
        while timelineViewModels.count > timelineCacheCapacity, !timelineAccessOrder.isEmpty {
            let candidateId = timelineAccessOrder.removeFirst()
            guard let vm = timelineViewModels[candidateId] else { continue }
            if !vm.isSuspended {
                vm.suspend()
            }
            timelineViewModels.removeValue(forKey: candidateId)
            _activityLog.log(
                category: .timeline, severity: .info, source: "MatrixService",
                summary: "Evicted timeline VM", roomId: candidateId
            )
        }
    }

    // MARK: - Room Management

    public func joinRoom(idOrAlias: String) async throws {
        guard let client = currentClient else { return }
        _ = try await client.joinRoomByIdOrAlias(roomIdOrAlias: idOrAlias, serverNames: [])
    }

    public func acceptInvite(roomId: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.join()
    }

    public func declineInvite(roomId: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.leave()
    }

    /// Power level overrides that allow any room member to send MatrixRTC call
    /// membership and encryption key state events (matching Element Call's setup).
    private static let callPowerLevels = PowerLevels(
        usersDefault: nil,
        eventsDefault: nil,
        stateDefault: nil,
        ban: nil,
        kick: nil,
        redact: nil,
        invite: nil,
        notifications: nil,
        users: [:],
        events: [
            "org.matrix.msc3401.call.member": 0,
            "io.element.call.encryption_keys": 0
        ]
    )

    public func createRoom(options: CreateRoomOptions) async throws -> String {
        let client = try requireClient()
        let params = CreateRoomParameters(
            name: options.name,
            topic: options.topic,
            isEncrypted: options.isEncrypted,
            isDirect: false,
            visibility: options.isPublic ? .public : .private,
            preset: options.isPublic ? .publicChat : .privateChat,
            powerLevelContentOverride: Self.callPowerLevels,
            canonicalAlias: options.address,
            isSpace: options.isSpace
        )
        return try await client.createRoom(parameters: params)
    }

    public func createDirectMessage(userId: String) async throws -> String {
        let client = try requireClient()

        // Check if a DM room already exists with this user
        if let existingRoom = try? client.getDmRoom(userId: userId) {
            return existingRoom.id()
        }

        // m.direct may lack a room that is a direct chat in every other way:
        // made by a client that never wrote the account data. A joined
        // two-person room flagged direct, with this user in it, is the
        // conversation; opening a second one beside it helps no one.
        for summary in rooms where summary.isDirect && summary.membership == .joined {
            guard let candidate = room(id: summary.id), candidate.joinedMembersCount() == 2,
                  let member = try? await candidate.member(userId: userId),
                  member.membership == .join else { continue }
            return summary.id
        }

        // Create a new DM room
        let params = CreateRoomParameters(
            name: nil,
            isEncrypted: true,
            isDirect: true,
            visibility: .private,
            preset: .trustedPrivateChat,
            invite: [userId],
            powerLevelContentOverride: Self.callPowerLevels
        )
        return try await client.createRoom(parameters: params)
    }

    public func makeRoomDirectoryViewModel() -> (any RoomDirectoryViewModelProtocol)? {
        guard let client = currentClient else { return nil }
        return RoomDirectoryViewModel(client: client, errorReporter: errorReporter)
    }

    public func makeMessageSearchService() -> (any MessageSearchServiceProtocol)? {
        guard let client = currentClient else { return nil }
        return MessageSearchService(client: client)
    }

    public func makeRoomPreviewViewModel(roomId: String) -> (any RoomPreviewViewModelProtocol)? {
        guard let client = currentClient else { return nil }
        return RoomPreviewViewModel(roomId: roomId, client: client, errorReporter: errorReporter)
    }

    public func makeSpaceHierarchyViewModel(spaceId: String) -> (any SpaceHierarchyViewModelProtocol)? {
        guard let client = currentClient else { return nil }
        let spaceName = spaceListManager.spaces.first(where: { $0.id == spaceId })?.name ?? ""
        return SpaceHierarchyViewModel(
            spaceId: spaceId,
            spaceName: spaceName,
            client: client,
            errorReporter: errorReporter
        )
    }

    public func leaveRoom(id: String) async throws {
        guard let room = room(id: id) else { return }
        try await room.leave()
        discardTimelines(ids: [id])
        roomListManager.removeRooms(ids: [id])
    }

    public func leaveSpace(spaceId: String) async throws -> [LeaveSpaceChild] {
        guard let client = currentClient else { return [] }
        let service = await client.spaceService()
        let handle = try await service.leaveSpace(spaceId: spaceId)
        return handle.rooms().map { room in
            LeaveSpaceChild(
                roomId: room.spaceRoom.roomId,
                name: room.spaceRoom.displayName,
                avatarURL: room.spaceRoom.avatarUrl,
                isLastOwner: room.isLastOwner,
                memberCount: room.spaceRoom.numJoinedMembers,
                isSpace: room.spaceRoom.roomType == .space
            )
        }
    }

    public func confirmLeaveSpace(spaceId: String, roomIds: [String]) async throws {
        guard let client = currentClient else { return }
        let service = await client.spaceService()
        let handle = try await service.leaveSpace(spaceId: spaceId)
        var allIds = roomIds
        if !allIds.contains(spaceId) {
            allIds.append(spaceId)
        }
        try await handle.leave(roomIds: allIds)
        discardTimelines(ids: allIds)
        let idSet = Set(allIds)
        roomListManager.removeRooms(ids: idSet)
        spaceListManager.removeSpaces(ids: idSet)
    }

    public func inviteUser(roomId: String, userId: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.inviteUserById(userId: userId)
    }

    public func setRoomName(roomId: String, name: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.setName(name: name)
    }

    public func setRoomTopic(roomId: String, topic: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.setTopic(topic: topic)
    }

    public func uploadRoomAvatar(roomId: String, mimeType: String, data: Data) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.uploadAvatar(mimeType: mimeType, data: data, mediaInfo: nil)
    }

    public func removeRoomAvatar(roomId: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.removeAvatar()
    }

    // MARK: Room Alias Management

    public func updateCanonicalAlias(roomId: String, alias: String?, altAliases: [String]) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.updateCanonicalAlias(alias: alias, altAliases: altAliases)
    }

    @discardableResult
    public func publishRoomAlias(roomId: String, alias: String) async throws -> Bool {
        guard let room = room(id: roomId) else { return false }
        return try await room.publishRoomAliasInRoomDirectory(alias: alias)
    }

    @discardableResult
    public func removeRoomAlias(roomId: String, alias: String) async throws -> Bool {
        guard let room = room(id: roomId) else { return false }
        return try await room.removeRoomAliasFromRoomDirectory(alias: alias)
    }

    public func isRoomAliasAvailable(alias: String) async throws -> Bool {
        let client = try requireClient()
        return try await client.isRoomAliasAvailable(alias: alias)
    }

    public func editableSpaces() async -> [EditableSpace] {
        guard let client = currentClient else { return [] }
        let service = await client.spaceService()
        let sdkSpaces = await service.editableSpaces()
        return sdkSpaces.map { spaceRoom in
            EditableSpace(
                roomId: spaceRoom.roomId,
                name: spaceRoom.displayName,
                avatarURL: spaceRoom.avatarUrl
            )
        }
    }

    public func addChildToSpace(childId: String, spaceId: String) async throws {
        let client = try requireClient()
        let service = await client.spaceService()
        try await service.addChildToSpace(childId: childId, spaceId: spaceId)
    }

    public func removeChildFromSpace(childId: String, spaceId: String) async throws {
        let client = try requireClient()
        let service = await client.spaceService()
        try await service.removeChildFromSpace(childId: childId, spaceId: spaceId)
    }

    public func setFavourite(roomId: String, isFavourite: Bool) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.setIsFavourite(isFavourite: isFavourite, tagOrder: nil)
    }

    // MARK: - Read Receipts & Typing

    public func markAsRead(roomId: String, sendPublicReceipt: Bool) async {
        guard let room = room(id: roomId) else { return }

        // Optimistically clear unread indicators so the room list updates immediately
        // rather than waiting for the server round-trip through the sync loop.
        // The isOptimisticallyCleared flag prevents the room info listener from
        // overwriting these zeros with stale server values before the server processes
        // the read receipt.
        if let summary = rooms.first(where: { $0.id == roomId }) {
            summary.optimisticClearedBaseline = summary.notificationCount
            summary.notificationCount = 0
            summary.highlightCount = 0
            summary.isOptimisticallyCleared = true
            summary.optimisticClearedAt = .now
        }

        let receiptType: ReceiptType = sendPublicReceipt ? .read : .readPrivate
        try? await room.markAsRead(receiptType: receiptType)
    }

    public func fullyReadEventId(roomId: String) async -> String? {
        guard let client = currentClient else { return nil }
        // Use a nonisolated(unsafe) var so the handle stays alive until the callback fires.
        nonisolated(unsafe) var handle: TaskHandle?
        let result: String? = await withCheckedContinuation { continuation in
            // The listener fires on every change, from the SDK's threads, and
            // not at all for a room never marked read: a continuation may be
            // resumed only once, and must be resumed at all.
            let once = OneShotContinuation(continuation)
            let listener = RoomAccountDataListenerAdapter { event, _ in
                if case .fullyReadEvent(let eventId) = event {
                    once.resume(eventId)
                } else {
                    once.resume(nil)
                }
            }
            do {
                handle = try client.observeRoomAccountDataEvent(
                    roomId: roomId,
                    eventType: .fullyRead,
                    listener: listener
                )
            } catch {
                once.resume(nil)
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                once.resume(nil)
            }
        }
        handle?.cancel()
        return result
    }

    public func sendTypingNotice(roomId: String, isTyping: Bool) async {
        guard let room = room(id: roomId) else { return }
        try? await room.typingNotice(isTyping: isTyping)
    }

    public func searchUsers(term: String, limit: Int) async throws -> [UserSearchResult] {
        let client = try requireClient()
        let results = try await client.searchUsers(searchTerm: term, limit: UInt64(max(1, limit)))
        return results.results.map {
            UserSearchResult(userId: $0.userId, displayName: $0.displayName, avatarURL: $0.avatarUrl)
        }
    }

    public func saveDraft(roomId: String, text: String) async {
        guard let room = room(id: roomId) else { return }
        if text.isEmpty {
            try? await room.clearComposerDraft(threadRoot: nil)
        } else {
            let draft = ComposerDraft(plainText: text, htmlText: nil, draftType: .newMessage, attachments: [])
            try? await room.saveComposerDraft(draft: draft, threadRoot: nil)
        }
    }

    public func loadDraft(roomId: String) async -> String? {
        guard let room = room(id: roomId) else { return nil }
        return try? await room.loadComposerDraft(threadRoot: nil)?.plainText
    }

    /// Sends a plain text message to a room without a timeline on screen:
    /// the Reply action of a notification.
    public func sendText(roomId: String, text: String) async throws {
        guard let room = room(id: roomId) else { throw RelayError.roomNotFound(roomId) }
        let content = messageEventContentFromMarkdown(md: text)
            .withMentions(mentions: Mentions(userIds: [], room: false))
        _ = try await room.timeline().send(msg: content)
    }

    public func donateOutgoingInteraction(roomId: String) {
        guard let roomSummary = rooms.first(where: { $0.id == roomId }) else { return }
        intentDonation.donateOutgoingMessage(roomSummary: roomSummary)
    }

    // MARK: - Room Details

    public func roomDetails(roomId: String) async -> RoomDetails? {
        guard let room = room(id: roomId) else { return nil }

        let info = try? await room.roomInfo()
        let name = room.displayName() ?? room.id()
        let topic = info?.topic
        let avatarUrl = room.avatarUrl()
        let isEncrypted = info?.encryptionState != .notEncrypted
        let isPublic = info?.isPublic ?? false
        let isDirect = info?.isDirect ?? false
        let canonicalAlias = room.canonicalAlias()
        let alternativeAliases = room.alternativeAliases()

        let memberCount = info?.joinedMembersCount ?? room.joinedMembersCount()

        var memberDetails: [RoomMemberDetails] = []
        if let membersIterator = try? await room.members() {
            let chunk = membersIterator.nextChunk(chunkSize: 200)
            if let chunk {
                memberDetails = chunk.compactMap(Self.mapMember)
            }
        }

        let pinnedEventIds = info?.pinnedEventIds ?? []

        let joinRuleString: String? = switch info?.joinRule {
        case .public: "public"
        case .invite: "invite"
        case .knock: "knock"
        case .restricted: "restricted"
        case .knockRestricted: "knock_restricted"
        case .custom(let rule): rule
        default: nil
        }

        let histVisString: String? = switch info?.historyVisibility {
        case .joined: "joined"
        case .invited: "invited"
        case .shared: "shared"
        case .worldReadable: "world_readable"
        default: nil
        }

        // Build permissions and power level settings from the SDK's power levels.
        var permissions: RoomPermissions?
        var powerLevelSettings: RoomPowerLevelSettings?
        if let pl = info?.powerLevels {
            permissions = RoomPermissions(
                canEditName: pl.canOwnUserSendState(stateEvent: .roomName),
                canEditTopic: pl.canOwnUserSendState(stateEvent: .roomTopic),
                canEditAvatar: pl.canOwnUserSendState(stateEvent: .roomAvatar),
                canInvite: pl.canOwnUserInvite(),
                canKick: pl.canOwnUserKick(),
                canBan: pl.canOwnUserBan(),
                canRedactOther: pl.canOwnUserRedactOther(),
                canChangePermissions: pl.canOwnUserSendState(stateEvent: .roomPowerLevels),
                canPin: pl.canOwnUserSendState(stateEvent: .roomPinnedEvents),
                canEditJoinRules: pl.canOwnUserSendState(stateEvent: .roomJoinRules),
                canEditHistoryVisibility: pl.canOwnUserSendState(stateEvent: .roomHistoryVisibility),
                canEditCanonicalAlias: pl.canOwnUserSendState(stateEvent: .roomCanonicalAlias),
                canSendMessages: pl.canOwnUserSendMessage(message: .roomMessage)
            )
            let values = pl.values()
            powerLevelSettings = RoomPowerLevelSettings(
                ban: values.ban,
                kick: values.kick,
                invite: values.invite,
                redact: values.redact,
                eventsDefault: values.eventsDefault,
                stateDefault: values.stateDefault,
                usersDefault: values.usersDefault,
                roomName: values.roomName,
                roomTopic: values.roomTopic,
                roomAvatar: values.roomAvatar
            )
        }

        return RoomDetails(
            id: room.id(),
            name: name,
            topic: topic,
            avatarURL: avatarUrl,
            isEncrypted: isEncrypted,
            isPublic: isPublic,
            isDirect: isDirect,
            canonicalAlias: canonicalAlias,
            alternativeAliases: alternativeAliases,
            memberCount: memberCount,
            members: memberDetails,
            pinnedEventIds: pinnedEventIds,
            joinRule: joinRuleString,
            historyVisibility: histVisString,
            permissions: permissions,
            powerLevelSettings: powerLevelSettings
        )
    }

    // MARK: - Room Members

    /// Converts an SDK ``RoomMember`` into a ``RoomMemberDetails``, filtering out non-joined members.
    private static func mapMember(_ member: RoomMember) -> RoomMemberDetails? {
        guard member.membership == .join else { return nil }
        let role: RoomMemberDetails.Role = switch member.suggestedRoleForPowerLevel {
        case .creator, .administrator: .administrator
        case .moderator: .moderator
        default: .user
        }
        let powerLevel: Int64 = switch member.powerLevel {
        case .value(let value): value
        case .infinite: 100
        }
        return RoomMemberDetails(
            userId: member.userId,
            displayName: member.displayName,
            avatarURL: member.avatarUrl,
            role: role,
            powerLevel: powerLevel,
            isCreator: member.suggestedRoleForPowerLevel == .creator
        )
    }

    public func roomMembers(roomId: String) async -> [RoomMemberDetails] {
        guard let room = room(id: roomId) else { return [] }

        var memberDetails: [RoomMemberDetails] = []
        guard let membersIterator = try? await room.members() else { return [] }

        while let chunk = membersIterator.nextChunk(chunkSize: 500) {
            memberDetails.append(contentsOf: chunk.compactMap(Self.mapMember))
        }

        return memberDetails
    }

    // MARK: - Pinned Messages

    // swiftlint:disable:next cyclomatic_complexity
    public func pinnedMessages(roomId: String) async -> [TimelineMessage] {
        guard let room = room(id: roomId) else {
            _activityLog.log(
                category: .timeline, severity: .warning, source: "MatrixService",
                summary: "Pinned messages: room not found", roomId: roomId
            )
            return []
        }

        let info = try? await room.roomInfo()
        let pinnedIds = info?.pinnedEventIds ?? []
        guard !pinnedIds.isEmpty else { return [] }

        let currentUser = userId()
        var messages: [TimelineMessage] = []

        // Fetch each pinned event directly from the server/cache using
        // Room.loadOrFetchEvent, which works regardless of whether the event
        // is in the loaded timeline window.
        for eventId in pinnedIds {
            do {
                let event = try await room.loadOrFetchEvent(eventId: eventId)
                let content = try event.content()

                guard case .messageLike(let msgContent) = content,
                      case .roomMessage(let messageType, _) = msgContent else {
                    continue
                }

                let body: String
                let kind: TimelineMessage.Kind
                // swiftlint:disable identifier_name
                switch messageType {
                case .text(let c):    body = c.body; kind = .text
                case .emote(let c):   body = c.body; kind = .emote
                case .notice(let c):  body = c.body; kind = .notice
                case .image:          body = "Image"; kind = .image
                case .video:          body = "Video"; kind = .video
                case .audio:          body = "Audio"; kind = .audio
                case .file:           body = "File";  kind = .file
                case .location:       body = "Location"; kind = .location
                case .gallery:        body = "Gallery"; kind = .image
                case .other(_, let b): body = b; kind = .other
                }
                // swiftlint:enable identifier_name

                let senderId = event.senderId()
                let displayName = try? await room.memberDisplayName(userId: senderId)
                let avatarURL = try? await room.memberAvatarUrl(userId: senderId)
                // swiftlint:disable:next identifier_name
                let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp()) / 1000)

                messages.append(TimelineMessage(
                    id: event.eventId(),
                    senderID: senderId,
                    senderDisplayName: displayName,
                    senderAvatarURL: avatarURL,
                    body: body,
                    timestamp: ts,
                    isOutgoing: senderId == currentUser,
                    kind: kind
                ))
            } catch {
                _activityLog.log(
                    category: .timeline, severity: .warning, source: "MatrixService",
                    summary: "Pinned messages: failed to fetch event \(eventId)",
                    detail: error.localizedDescription, roomId: roomId
                )
            }
        }

        return messages
    }

    // MARK: - Media

    public func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? {
        guard let client = currentClient else { return nil }
        return await media.avatarThumbnail(mxcURL: mxcURL, size: size, client: client)
    }

    public func mediaContent(mxcURL: String, mediaSourceJSON: String?) async -> Data? {
        guard let client = currentClient else { return nil }
        return await media.mediaContent(mxcURL: mxcURL, mediaSourceJSON: mediaSourceJSON, client: client)
    }

    public func mediaThumbnail(mxcURL: String, mediaSourceJSON: String?, width: UInt64, height: UInt64) async -> Data? {
        guard let client = currentClient else { return nil }
        return await media.mediaThumbnail(mxcURL: mxcURL, mediaSourceJSON: mediaSourceJSON, width: width, height: height, client: client)
    }

    // MARK: - Notification Settings

    private func notificationSettings() async throws -> NotificationSettings {
        let client = try requireClient()
        return await client.getNotificationSettings()
    }

    public func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode {
        let settings = try await notificationSettings()
        let mode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: isOneToOne)
        return DefaultNotificationMode(sdkMode: mode)
    }

    public func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {
        let settings = try await notificationSettings()
        try await settings.setDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: isOneToOne, mode: mode.sdkMode)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: isOneToOne, mode: mode.sdkMode)
        if isOneToOne {
            defaultDirectNotificationMode = mode
        } else {
            defaultGroupNotificationMode = mode
        }
    }

    /// Reads the account's default levels once per session, for the Dock
    /// badge: a room without a rule of its own counts by these, not by a
    /// guess of what they might be.
    private func refreshDefaultNotificationModes() async {
        defaultDirectNotificationMode = (try? await getDefaultNotificationMode(isOneToOne: true)) ?? .allMessages
        defaultGroupNotificationMode = (try? await getDefaultNotificationMode(isOneToOne: false)) ?? .mentionsAndKeywordsOnly
    }

    public func hasConsistentNotificationSettings() async throws -> Bool {
        let settings = try await notificationSettings()

        let directEncrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: true)
        let directUnencrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: true)
        let groupEncrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: false)
        let groupUnencrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: false)

        return directEncrypted == directUnencrypted && groupEncrypted == groupUnencrypted
    }

    public func fixInconsistentNotificationSettings() async throws {
        let settings = try await notificationSettings()

        // For each chat type, read the encrypted mode and apply it to unencrypted as well
        let directMode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: true)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: true, mode: directMode)

        let groupMode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: false)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: false, mode: groupMode)
    }

    public func roomsWithCustomNotificationSettings() async throws -> [String] {
        let settings = try await notificationSettings()
        let ids = await settings.getRoomsWithUserDefinedRules(enabled: true)
        return Array(Set(ids))
    }

    public func isCallNotificationEnabled() async throws -> Bool {
        try await notificationSettings().isCallEnabled()
    }

    public func setCallNotificationEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setCallEnabled(enabled: enabled)
    }

    public func isInviteNotificationEnabled() async throws -> Bool {
        try await notificationSettings().isInviteForMeEnabled()
    }

    public func setInviteNotificationEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setInviteForMeEnabled(enabled: enabled)
    }

    public func isRoomMentionEnabled() async throws -> Bool {
        try await notificationSettings().isRoomMentionEnabled()
    }

    public func setRoomMentionEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setRoomMentionEnabled(enabled: enabled)
    }

    public func isUserMentionEnabled() async throws -> Bool {
        try await notificationSettings().isUserMentionEnabled()
    }

    public func setUserMentionEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setUserMentionEnabled(enabled: enabled)
    }

    // MARK: - Keyword Notification Settings

    public func getNotificationKeywords() async throws -> [String] {
        let client = try requireClient()
        let session = try client.session()

        var request = URLRequest(
            url: URL(string: "\(client.homeserver)_matrix/client/v3/pushrules/global/")!
        )
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let ruleset = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ruleset["content"] as? [[String: Any]]
        else {
            return []
        }

        var keywords: [String] = []

        for rule in content {
            guard let isDefault = rule["default"] as? Bool, !isDefault,
                  let enabled = rule["enabled"] as? Bool, enabled,
                  let actions = rule["actions"] as? [Any], !actions.isEmpty,
                  let pattern = rule["pattern"] as? String
            else { continue }
            keywords.append(pattern)
        }

        return keywords
    }

    /// The request body for creating a content-type push rule via the Matrix
    /// REST API. Uses `Codable` for type-safe JSON serialization.
    private struct ContentPushRuleBody: Encodable {
        enum Action: Encodable {
            case notify
            case setTweak(name: String, value: String? = nil)

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .notify:
                    try container.encode("notify")
                case .setTweak(let name, let value):
                    var tweakDict: [String: String] = ["set_tweak": name]
                    if let value { tweakDict["value"] = value }
                    try container.encode(tweakDict)
                }
            }
        }

        let pattern: String
        let actions: [Action]
    }

    public func addNotificationKeyword(_ keyword: String) async throws {
        let client = try requireClient()
        let session = try client.session()

        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        let url = URL(string: "\(client.homeserver)_matrix/client/v3/pushrules/global/content/\(encodedKeyword)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ContentPushRuleBody(
            pattern: keyword,
            actions: [.notify, .setTweak(name: "highlight"), .setTweak(name: "sound", value: "default")]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            let serverMessage = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.notificationSettingsFailed("Failed to add keyword rule: \(serverMessage)")
        }

        if !cachedNotificationKeywords.contains(keyword) {
            cachedNotificationKeywords.append(keyword)
        }
        roomListManager.notificationKeywords = cachedNotificationKeywords
    }

    public func removeNotificationKeyword(_ keyword: String) async throws {
        let client = try requireClient()
        let session = try client.session()

        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        let url = URL(string: "\(client.homeserver)_matrix/client/v3/pushrules/global/content/\(encodedKeyword)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            let serverMessage = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.notificationSettingsFailed("Failed to remove keyword rule: \(serverMessage)")
        }

        cachedNotificationKeywords.removeAll { $0 == keyword }
        roomListManager.notificationKeywords = cachedNotificationKeywords
    }

    // MARK: - Per-Room Notification Settings

    public func getRoomNotificationMode(roomId: String) async throws -> RelayInterface.RoomNotificationMode? {
        guard let sdkRoom = room(id: roomId) else { return nil }
        let settings = try await notificationSettings()
        let info = try? await sdkRoom.roomInfo()
        let isEncrypted = info?.encryptionState != .notEncrypted
        let isOneToOne = info?.isDirect ?? false
        let roomSettings = try await settings.getRoomNotificationSettings(
            roomId: roomId,
            isEncrypted: isEncrypted,
            isOneToOne: isOneToOne
        )
        guard !roomSettings.isDefault else { return nil }
        return RelayInterface.RoomNotificationMode(sdkMode: roomSettings.mode)
    }

    public func setRoomNotificationMode(
        roomId: String,
        mode: RelayInterface.RoomNotificationMode
    ) async throws {
        let settings = try await notificationSettings()
        try await settings.setRoomNotificationMode(roomId: roomId, mode: mode.sdkMode)
    }

    public func restoreDefaultRoomNotificationMode(roomId: String) async throws {
        let settings = try await notificationSettings()
        try await settings.restoreDefaultRoomNotificationMode(roomId: roomId)
    }

    // MARK: - Power Levels

    public func setMemberPowerLevel(roomId: String, userId: String, powerLevel: Int64) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let update = UserPowerLevelUpdate(userId: userId, powerLevel: powerLevel)
        try await sdkRoom.updatePowerLevelsForUsers(updates: [update])
    }

    public func updatePowerLevelSettings(roomId: String, settings: RoomPowerLevelSettings) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let changes = RoomPowerLevelChanges(
            ban: settings.ban,
            invite: settings.invite,
            kick: settings.kick,
            redact: settings.redact,
            eventsDefault: settings.eventsDefault,
            stateDefault: settings.stateDefault,
            usersDefault: settings.usersDefault,
            roomName: settings.roomName,
            roomAvatar: settings.roomAvatar,
            roomTopic: settings.roomTopic
        )
        try await sdkRoom.applyPowerLevelChanges(changes: changes)
    }

    // MARK: - Room Access Settings

    public func updateJoinRule(roomId: String, rule: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let joinRule: JoinRule = switch rule {
        case "public": .public
        case "invite": .invite
        case "knock": .knock
        default: .invite
        }
        try await sdkRoom.updateJoinRules(newRule: joinRule)
    }

    public func updateHistoryVisibility(roomId: String, visibility: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let histVis: MatrixRustSDK.RoomHistoryVisibility = switch visibility {
        case "joined": .joined
        case "invited": .invited
        case "shared": .shared
        case "world_readable": .worldReadable
        default: .shared
        }
        try await sdkRoom.updateHistoryVisibility(visibility: histVis)
    }

    public func updateRoomVisibility(roomId: String, isPublic: Bool) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let visibility: RoomVisibility = isPublic ? .public : .private
        try await sdkRoom.updateRoomVisibility(visibility: visibility)
    }

    // MARK: - Member Moderation

    public func kickMember(roomId: String, userId: String, reason: String?) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.kickUser(userId: userId, reason: reason)
    }

    public func banMember(roomId: String, userId: String, reason: String?) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.banUser(userId: userId, reason: reason)
    }

    public func unbanMember(roomId: String, userId: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.unbanUser(userId: userId, reason: nil)
    }

    // MARK: - Ignore List

    public func isUserIgnored(userId: String) async throws -> Bool {
        guard let client = currentClient else { return false }
        let ignored = try await client.ignoredUsers()
        return ignored.contains(userId)
    }

    public func ignoreUser(userId: String) async throws {
        let client = try requireClient()
        try await client.ignoreUser(userId: userId)
    }

    public func unignoreUser(userId: String) async throws {
        let client = try requireClient()
        try await client.unignoreUser(userId: userId)
    }

    // MARK: - Moderation

    public func reportContent(roomId: String, eventId: String, reason: String?) async throws {
        let client = try requireClient()
        guard let room = try client.getRoom(roomId: roomId) else {
            throw RelayError.roomNotFound(roomId)
        }
        try await room.reportContent(eventId: eventId, reason: reason)
    }

    public func reportRoom(roomId: String, reason: String) async throws {
        let client = try requireClient()
        guard let room = try client.getRoom(roomId: roomId) else {
            throw RelayError.roomNotFound(roomId)
        }
        try await room.reportRoom(reason: reason)
    }

    // MARK: - Account Management

    public func accountManagementURL(action: AccountAction?) async throws -> String? {
        let client = try requireClient()
        return try await client.accountURL(action: action.map(Self.sdkAction))
    }

    /// Translates Plic's own account action into the SDK's.
    ///
    /// The indirection exists because `RelayInterface` carries no SDK
    /// dependency — that is what keeps Xcode previews from loading the Rust
    /// binary — so the shared protocol cannot name an SDK type.
    private static func sdkAction(_ action: AccountAction) -> AccountManagementAction {
        switch action {
        case .profile: .profile
        case .devices: .devicesList
        case .deactivate: .accountDeactivate
        }
    }

    // MARK: - Session Verification

    public func makeSessionVerificationViewModel(acceptingIncomingRequest: Bool = false) async throws -> (any SessionVerificationViewModelProtocol)? {
        guard let controller = verificationController else { return nil }
        if !acceptingIncomingRequest {
            controller.resetFlowState()
        }
        isVerificationFlowActive = true
        let viewModel = SessionVerificationViewModel(
            controller: controller, service: self,
            errorReporter: errorReporter, activityLog: _activityLog,
            acceptingIncomingRequest: acceptingIncomingRequest
        )
        // Reset the flag when the view model is deallocated (sheet dismissed).
        Task { [weak self, weak viewModel] in
            // Wait until the view model is released.
            while viewModel != nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.isVerificationFlowActive = false
        }
        return viewModel
    }

    public func makeCallViewModel(roomId: String) async -> (any CallViewModelProtocol)? {
        guard let client = currentClient else { return nil }
        do {
            let session = try client.session()
            // Whether the room is encrypted decides whether the call's media
            // is. Unknown is not "no": a call that silently went out in the
            // clear because a lookup failed is the one outcome to avoid.
            guard let sdkRoom = room(id: roomId), let info = try? await sdkRoom.roomInfo() else {
                _activityLog.log(
                    category: .call, severity: .error, source: "MatrixService",
                    summary: "Call refused: the room's encryption state is unknown",
                    roomId: roomId
                )
                return nil
            }
            let isEncrypted = info.encryptionState != .notEncrypted
            let context = CallViewModel.EncryptionContext(
                homeserver: client.homeserver,
                accessToken: session.accessToken,
                userID: client.userID,
                deviceID: client.deviceID,
                roomID: roomId,
                isRoomEncrypted: isEncrypted,
                matrixRoom: sdkRoom
            )
            let viewModel = CallViewModel(encryptionContext: context)
            viewModel.activityLog = _activityLog
            _activityLog.log(
                category: .call, severity: .info, source: "MatrixService",
                summary: "Created call view model",
                detail: "E2EE: \(isEncrypted ? "enabled" : "disabled")",
                roomId: roomId
            )
            return viewModel
        } catch {
            _activityLog.log(
                category: .call, severity: .error, source: "MatrixService",
                summary: "Call refused: no session for the call",
                detail: error.localizedDescription, roomId: roomId
            )
            return nil
        }
    }

    public func callCredentials(for roomId: String) async throws -> (livekitURL: String, token: String, sfuServiceURL: String) {
        guard let client else {
            throw LiveKitCredentialError.serverError
        }
        let session = try client.session()
        // Extract the server name from the user ID (e.g. "@user:fedora.im" → "fedora.im").
        // .well-known must be queried on the server name domain, not the delegated homeserver.
        let serverName = client.userID.split(separator: ":").dropFirst().joined(separator: ":")
        let service = LiveKitCredentialService(
            homeserver: client.homeserver,
            accessToken: session.accessToken,
            userID: client.userID,
            deviceID: client.deviceID,
            serverName: serverName,
            activityLog: _activityLog
        )
        let result = try await service.credentials(for: roomId)
        return (livekitURL: result.url, token: result.token, sfuServiceURL: result.sfuServiceURL)
    }

    public func declinePendingVerificationRequest() async {
        pendingVerificationRequest = nil
        try? await verificationController?.cancelVerification()
    }

    public func isCurrentSessionVerified() async -> Bool {
        guard let client = currentClient else { return false }
        return client.encryption().verificationState() == .verified
    }

    public func encryptionState() async -> EncryptionStatus {
        guard let client = currentClient else { return EncryptionStatus() }
        let encryption = client.encryption()
        return EncryptionStatus(
            backupEnabled: encryption.backupState() == .enabled,
            recoveryEnabled: encryption.recoveryState() == .enabled
        )
    }

    public func hasDevicesToVerifyAgainst() async throws -> Bool {
        let client = try requireClient()
        return try await client.encryption().hasDevicesToVerifyAgainst()
    }

    public func recoverWithKey(_ recoveryKey: String) async throws {
        let client = try requireClient()
        try await client.encryption().recover(recoveryKey: recoveryKey)
    }

    // MARK: - Devices

    // swiftlint:disable nesting
    private struct DevicesResponse: Decodable {
        struct Device: Decodable {
            let deviceId: String
            let displayName: String?
            let lastSeenIP: String?
            let lastSeenTS: UInt64?

            enum CodingKeys: String, CodingKey {
                case deviceId = "device_id"
                case displayName = "display_name"
                case lastSeenIP = "last_seen_ip"
                case lastSeenTS = "last_seen_ts"
            }
        }
        let devices: [Device]
    }
    // swiftlint:enable nesting

    public func getDevices() async throws -> [DeviceInfo] {
        let client = try requireClient()

        let currentDeviceId = client.deviceID
        let session = try client.session()

        var request = URLRequest(url: URL(string: "\(client.homeserver)_matrix/client/v3/devices")!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(DevicesResponse.self, from: data)

        return response.devices.map { device in
            let lastSeen: Date? = device.lastSeenTS.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            return DeviceInfo(
                id: device.deviceId,
                displayName: device.displayName,
                lastSeenIP: device.lastSeenIP,
                lastSeenTimestamp: lastSeen,
                isCurrentDevice: device.deviceId == currentDeviceId
            )
        }
    }
}

/// Resumes a continuation at most once, from whichever thread gets there first.
nonisolated private final class OneShotContinuation<T: Sendable>: Sendable {
    private let pending: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        pending = Mutex(continuation)
    }

    func resume(_ value: T) {
        let continuation = pending.withLock { slot -> CheckedContinuation<T, Never>? in
            defer { slot = nil }
            return slot
        }
        continuation?.resume(returning: value)
    }
}
