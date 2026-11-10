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

import Intents
import os
import RelayKit
import RelayInterface
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "Relay", category: "DeepLink")

/// The main entry point for the Relay macOS application.
///
/// ``RelayApp`` creates the ``MatrixService``, injects it into the SwiftUI environment,
/// manages the dock badge for unread counts, and posts local notifications for new
/// mentions, direct messages, and incoming verification requests.
@main
struct RelayApp: App {
    /// `true` when Xcode is running the process solely to render SwiftUI
    /// previews. Checked once at launch so that heavy services (Matrix SDK,
    /// keychain, network monitor, etc.) are never created in preview mode.
    private static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    init() {
        // Carries an existing Colored choice over from the Bool this setting
        // used to be, before any view reads the new key. Without it, anyone
        // who had picked Colored would silently land back on Grey.
        MessageBubbleStyle.migrateLegacySettingIfNeeded()

        // Attachments are viewed and played from memory; nothing decrypted is
        // written to disk. Earlier builds did write copies, and this removes
        // any they left behind.
        MediaFileHelper.removeDecryptedFiles()
    }

    @State private var matrixService = MatrixService()
    @State private var callManager = CallManager()
    @State private var notificationDelegate = NotificationDelegate()
    @State private var appActions = AppActions()
    @State private var composeDraftStore = ComposeDraftStore()
    /// Held here so playback outlives every timeline rebuild below it.
    @State private var audioPlayback = AudioPlaybackCoordinator()
    @State private var showClearCacheConfirmation = false

    @Environment(\.openWindow) private var openWindow

    @AppStorage("selectedRoomId") private var selectedRoomId: String?
    @AppStorage("appearance.mode") private var appearanceMode: AppAppearance = .system
    @AppStorage(NotificationPreview.key) private var notificationPreview = NotificationPreview.standard

    var body: some Scene {
        WindowGroup(id: "main") {
            contentView
        }
        .defaultSize(width: 880, height: 560)
        .commands {
            FileMenuCommands(appActions: appActions)
            EditLastMessageCommand()
            SearchCommand(appActions: appActions)
            QuickSwitchCommand(appActions: appActions)
            ConversationCommands(appActions: appActions)
            SidebarCommands()
            InspectorCommands()
            TextSizeCommands()
            CommandGroup(before: .appTermination) {
                Button("Clear Cache…") {
                    showClearCacheConfirmation = true
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Plic") {
                    NSApp.activate()
                    if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                        window.deminiaturize(nil)
                        window.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate()
                    } else {
                        openWindow(id: "main")
                    }
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(\.matrixService, matrixService)
                .environment(\.audioPlayback, audioPlayback)
                .environment(\.errorReporter, matrixService.errorReporter)
                .preferredColorScheme(appearanceMode.colorScheme)
                // Also here: the setting can change while no main window is open.
                .onChange(of: notificationPreview) {
                    applyNotificationPreview()
                }
        }

        Window("Activity Log", id: "activity-log") {
            ActivityLogView()
                .environment(\.matrixService, matrixService)
                .environment(\.activityLog, matrixService.activityLog)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .defaultSize(width: 900, height: 600)
        .keyboardShortcut("a", modifiers: [.option, .command])

        Window("Call", id: "call") {
            CallWindowView()
                .environment(\.matrixService, matrixService)
                .environment(\.callManager, callManager)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 540)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
    }

    /// The root content view, configured with real services at runtime or
    /// bare (using environment-key defaults) during Xcode previews.
    @ViewBuilder private var contentView: some View {
        if Self.isPreview {
            ContentView()
                .preferredColorScheme(appearanceMode.colorScheme)
        } else {
            ContentView()
                .environment(\.matrixService, matrixService)
                .environment(\.callManager, callManager)
                .environment(\.errorReporter, matrixService.errorReporter)
                .environment(\.composeDraftStore, composeDraftStore)
                .environment(appActions)
                .background {
                    if appearanceMode.usesGlass {
                        LiquidGlassBackdrop()
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                .background(GlassWindowConfigurator(usesGlass: appearanceMode.usesGlass))
                .onChange(of: dockBadgeCount) { _, newCount in
                    NSApp.dockTile.badgeLabel = newCount > 0 ? "\(newCount)" : nil
                }
                .onChange(of: matrixService.authState) { _, state in
                    if state == .loggedOut {
                        composeDraftStore.removeAll()
                        // Delivered banners hold decrypted text; the last
                        // room is the previous account's.
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        selectedRoomId = nil
                        // Per-room settings are keyed by room ID, and those
                        // IDs are the previous account's too.
                        RoomBehaviorStore.shared.removeAll()
                    }
                }
                .onChange(of: notificationPreview, initial: true) {
                    applyNotificationPreview()
                }
                .onChange(of: matrixService.pendingVerificationRequest?.id) { _, newValue in
                    if newValue != nil, let request = matrixService.pendingVerificationRequest {
                        postVerificationNotification(request: request)
                    }
                }
                .onOpenURL { url in
                    if let uri = MatrixURI(url: url) {
                        logger.info("Received deep link: \(url.absoluteString)")
                        matrixService.pendingDeepLink = uri
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    checkForPendingShare()
                }
                .onContinueUserActivity(NSStringFromClass(INSendMessageIntent.self)) { activity in
                    if let intent = activity.interaction?.intent as? INSendMessageIntent,
                       let roomId = intent.conversationIdentifier {
                        logger.info("Received share suggestion for room: \(roomId)")
                        appActions.pendingRoomId = roomId
                    }
                }
                .task {
                    await setupNotifications()
                    matrixService.onNotificationEvent = { event in
                        Task { @MainActor in
                            self.handleNotificationEvent(event)
                        }
                    }
                }
                .alert("Clear Cache", isPresented: $showClearCacheConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear Cache", role: .destructive) {
                        Task { await matrixService.clearLocalData() }
                    }
                } message: {
                    Text("This will delete all locally cached data and resync from the server. You will remain logged in.")
                }
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }

    // MARK: - Notifications

    private func setupNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        notificationDelegate.matrixService = matrixService
        notificationDelegate.appActions = appActions
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])

        // Register the verification request notification category with an Accept action.
        let acceptAction = UNNotificationAction(
            identifier: NotificationDelegate.acceptActionIdentifier,
            title: "Accept",
            options: [.foreground]
        )
        let verificationCategory = UNNotificationCategory(
            identifier: NotificationDelegate.verificationCategoryIdentifier,
            actions: [acceptAction],
            intentIdentifiers: []
        )
        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationDelegate.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let roomMessageCategory = UNNotificationCategory(
            identifier: NotificationDelegate.roomMessageCategoryIdentifier,
            actions: [replyAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([verificationCategory, roomMessageCategory])
    }

    /// The total dock badge count, computed from every room's notification-worthy unread state.
    ///
    /// Because ``RoomSummary`` is `@Observable`, SwiftUI tracks each property
    /// access and re-evaluates this whenever any room's unread state changes.
    /// The count respects each room's effective notification mode:
    /// - All Messages: counts all unread messages
    /// - Mentions & Keywords Only: counts only unread mentions
    /// - Mute: counts nothing
    private var dockBadgeCount: UInt {
        matrixService.rooms.reduce(0 as UInt) { total, room in
            switch room.notificationMode {
            case .mute:
                return total
            case .mentionsAndKeywordsOnly:
                return total + room.highlightCount
            case .allMessages:
                return total + room.notificationCount
            case nil:
                // No rule of its own: the account's default for its kind.
                let fallback = room.isDirect
                    ? matrixService.defaultDirectNotificationMode
                    : matrixService.defaultGroupNotificationMode
                switch fallback {
                case .mute: return total
                case .mentionsAndKeywordsOnly: return total + room.highlightCount
                case .allMessages: return total + room.notificationCount
                }
            }
        }
    }

    /// Handles a notification event from the room list manager.
    ///
    /// Posts a system notification banner and/or plays a sound when a room has new
    /// unread activity, respecting the room's effective notification mode:
    /// - **All Messages**: sound + banner for every message.
    /// - **Mentions & Keywords Only**: sound + banner only for mentions.
    /// - **Mute**: no sound or banner.
    /// - **Default** (`nil`): DMs behave as All Messages; groups as Mentions & Keywords Only.
    ///
    /// When the user is actively viewing the room, the banner is suppressed but
    /// the sound still plays (if warranted by the notification mode).
    private func handleNotificationEvent(_ event: RoomNotificationEvent) {
        // Determine the effective notification mode for this room.
        // When there is no per-room override, DMs default to "All Messages"
        // and groups default to "Mentions & Keywords Only".
        let effectiveMode: RelayInterface.RoomNotificationMode = event.notificationMode
            ?? (event.isDirect ? .allMessages : .mentionsAndKeywordsOnly)

        // Muted rooms produce no sound, banner, or other system notification.
        guard effectiveMode != .mute else { return }

        // For "Mentions & Keywords Only", only notify when the message is a mention.
        if effectiveMode == .mentionsAndKeywordsOnly, !event.isMention {
            return
        }

        let content = UNMutableNotificationContent()

        let preview = UserDefaults.standard.string(forKey: NotificationPreview.key)
            .flatMap(NotificationPreview.init(rawValue:)) ?? .standard
        let banner = preview.banner(
            roomName: event.roomName, author: event.messageAuthor,
            message: event.messageBody, isDirect: event.isDirect
        )
        content.title = banner.title
        content.body = banner.body
        content.sound = .default
        content.threadIdentifier = event.roomId
        content.userInfo = ["roomId": event.roomId]
        content.categoryIdentifier = NotificationDelegate.roomMessageCategoryIdentifier

        // Suppress the banner when the user is actively viewing this room,
        // but still deliver the notification so the sound plays.
        if NSApp.isActive, selectedRoomId == event.roomId {
            content.interruptionLevel = .passive
        }

        let request = UNNotificationRequest(
            identifier: "room-\(event.roomId)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Suggests conversations to macOS only when notifications may name them.
    ///
    /// With No Name or Message chosen, the share sheet's suggestions would
    /// still hand macOS the room and sender names the user chose to withhold.
    private func applyNotificationPreview() {
        matrixService.allowsShareSuggestions = notificationPreview != .nothing
    }

    /// Checks the app group container for a pending share from the share extension.
    ///
    /// The extension writes the share ID to `latest-share-id.txt` and activates
    /// the app. This method reads that file, loads the corresponding pending share
    /// record, navigates to the target room, and stages the attachments in the
    /// compose bar for user review.
    private func checkForPendingShare() {
        guard let container = AppGroup.containerURL else { return }

        let signalURL = container.appending(path: "latest-share-id.txt")
        guard let idString = try? String(contentsOf: signalURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let shareId = UUID(uuidString: idString) else {
            return
        }

        // Remove the signal file immediately to avoid re-processing.
        try? FileManager.default.removeItem(at: signalURL)

        let pendingShares = PendingShareStore.loadAll()
        guard let share = pendingShares.first(where: { $0.id == shareId }) else {
            logger.warning("Pending share not found: \(idString)")
            return
        }

        logger.info("Share handoff: \(share.filenames.count) file(s) for room \(share.roomId)")

        // Navigate to the target room.
        appActions.pendingRoomId = share.roomId

        // Resolve file URLs from the app group container and stage them.
        let fileURLs = share.filenames.compactMap { PendingShareStore.fileURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !fileURLs.isEmpty else {
            logger.warning("No valid files found for pending share \(idString)")
            PendingShareStore.remove(id: shareId)
            return
        }

        // Stage attachments in the compose bar for the target room.
        let draft = composeDraftStore.draft(for: share.roomId)
        draft.stageAttachments(fileURLs, errorReporter: matrixService.errorReporter)

        // Remove the pending share record (files will be cleaned up after send
        // by TimelineViewModel.sendAttachment, which deletes the temp URL).
        PendingShareStore.remove(id: shareId)
    }

    private func postVerificationNotification(request: IncomingVerificationRequest) {
        let content = UNMutableNotificationContent()
        content.title = "Verification Request"
        content.body = "Another device (\(request.deviceId)) wants to verify this session."
        content.sound = .default
        content.categoryIdentifier = NotificationDelegate.verificationCategoryIdentifier
        content.userInfo = ["flowId": request.flowId]

        let notificationRequest = UNNotificationRequest(
            identifier: "verification-\(request.flowId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notificationRequest)
    }
}

// MARK: - App Actions

/// Shared observable state that bridges menu commands with the main view hierarchy.
///
/// ``AppActions`` is created at the app level and injected into both the SwiftUI
/// environment (for views) and the ``FileMenuCommands`` struct. ``MainView``
/// observes these flags and presents the corresponding UI.
@Observable
final class AppActions {
    var showNewMessage = false
    var showCreateRoom = false
    var showCreateSpace = false
    var showJoinRoom = false
    var showRoomDirectory = false
    var focusSearch = false
    /// A room to open, asked for from outside the window: a notification, a
    /// share from another app or a Share menu suggestion. The main view
    /// takes it and clears it.
    var pendingRoomId: String?
    var showQuickSwitch = false
    /// Requests to move the selection in the sidebar: incremented for the
    /// next conversation, decremented for the previous one.
    var roomStep = 0
}

// MARK: - File Menu Commands

/// Replaces the default File menu items with room-related commands.
///
/// The standard "New Window" item is removed since Relay supports only a single window.
struct FileMenuCommands: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // ⌘N is New Message, as in Messages and Mail; rooms and spaces
            // take the modifier keys.
            Button("New Message…") {
                appActions.showNewMessage = true
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Create Room…") {
                appActions.showCreateRoom = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Create Space…") {
                appActions.showCreateSpace = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Join Room…") {
                appActions.showJoinRoom = true
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Public Rooms Directory") {
                appActions.showRoomDirectory = true
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Edit Last Message Command

/// Adds an "Edit Last Message" item (⌘E) to the Edit menu.
///
/// The command reads the ``EditLastMessageKey`` focused value published by
/// ``TimelineView``.  When a timeline is focused and contains at least one
/// outgoing text message, pressing ⌘E starts editing that message.
struct EditLastMessageCommand: Commands {
    @FocusedValue(\.editLastMessage) private var editLastMessage

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Edit Last Message") {
                editLastMessage?()
            }
            // Not ⌘E, which macOS gives to "Use Selection for Find".
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(editLastMessage == nil)
        }
    }
}

// MARK: - Search Command

/// Adds a "Search…" item (⌘G) to the Edit menu.
///
/// When pressed, the command sets ``AppActions/focusSearch`` to `true`.
/// ``MainView`` observes this flag and moves keyboard focus to the
/// toolbar search field.
struct SearchCommand: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Search\u{2026}") {
                appActions.focusSearch = true
            }
            // ⌘F, as in Messages and Mail; ⌘G is "Find Next" everywhere else.
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}

// MARK: - Conversation Commands

/// A Conversation menu, as Messages has one: the next and previous
/// conversation in the sidebar's current order, on Messages' own keys.
struct ConversationCommands: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandMenu("Conversation") {
            Button("Next Conversation") {
                appActions.roomStep += 1
            }
            .keyboardShortcut(.tab, modifiers: .control)

            Button("Previous Conversation") {
                appActions.roomStep -= 1
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
    }
}

// MARK: - Quick Switch Command

/// Adds a "Quick Switch…" item (⌘K) to the Edit menu.
///
/// When pressed, the command sets ``AppActions/showQuickSwitch`` to `true`.
/// ``MainView`` observes this flag and presents the quick room switch overlay.
struct QuickSwitchCommand: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Quick Switch\u{2026}") {
                appActions.showQuickSwitch = true
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}

// MARK: - Text Size Commands

/// Adds message text-zoom items to the View menu: Increase Text Size (⌘+),
/// Reset Text Size (⌥⌘0), and Decrease Text Size (⌘−).
///
/// Each adjusts ``MessageTextScale``, which rescales the conversation text,
/// mention pills, and the compose field together.
struct TextSizeCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Increase Text Size") {
                MessageTextScale.increase()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Reset Text Size") {
                MessageTextScale.reset()
            }
            .keyboardShortcut("0", modifiers: [.option, .command])

            Button("Decrease Text Size") {
                MessageTextScale.decrease()
            }
            .keyboardShortcut("-", modifiers: .command)
        }
    }
}

// MARK: - Notification Delegate

/// Handles notification presentation and user interactions for local notifications.
///
/// When the user taps the verification notification or its "Accept" action,
/// the delegate creates a ``SessionVerificationViewModel`` and presents the
/// verification sheet via ``MatrixService/showVerificationSheet``.
/// When the user taps a room message notification, the delegate navigates to
/// that room by setting the `selectedRoomId` in `UserDefaults`.
@Observable
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let verificationCategoryIdentifier = "VERIFICATION_REQUEST"
    nonisolated static let acceptActionIdentifier = "ACCEPT_VERIFICATION"
    nonisolated static let roomMessageCategoryIdentifier = "ROOM_MESSAGE"
    nonisolated static let replyActionIdentifier = "REPLY_TO_ROOM"

    weak var matrixService: MatrixService?
    weak var appActions: AppActions?

    /// Show notifications even when the app is in the foreground.
    ///
    /// When a notification has `.passive` interruption level (set when the user is
    /// actively viewing the room), the banner is suppressed but the sound still plays.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.content.interruptionLevel == .passive {
            return [.sound]
        }
        return [.banner, .sound]
    }

    /// Handle the user tapping a notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content

        if content.categoryIdentifier == Self.verificationCategoryIdentifier {
            await MainActor.run {
                matrixService?.shouldPresentVerificationSheet = true
            }
            return
        }

        if content.categoryIdentifier == Self.roomMessageCategoryIdentifier {
            let roomId = content.userInfo["roomId"] as? String

            // Typed into the banner: sent without bringing the window up.
            if let reply = response as? UNTextInputNotificationResponse,
               response.actionIdentifier == Self.replyActionIdentifier {
                let text = reply.userText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let roomId, !text.isEmpty else { return }
                await MainActor.run {
                    Task { try? await matrixService?.sendText(roomId: roomId, text: text) }
                }
                return
            }

            await MainActor.run {
                if let roomId {
                    // For a window that is not up yet, and for one that is.
                    UserDefaults.standard.set(roomId, forKey: "selectedRoomId")
                    appActions?.pendingRoomId = roomId
                }
                NSApp.activate()
                if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
    }
}
