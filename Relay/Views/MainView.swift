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

import RelayInterface
import SwiftUI

/// The primary navigation view shown after login, with a room list sidebar and detail area.
///
/// ``MainView`` uses a `NavigationSplitView` with the room list in the sidebar and the
/// selected room's detail view (or compose view) in the detail area. An optional inspector
/// panel on the trailing edge shows room info or a selected user's profile.
/// Identifies a space whose settings sheet is open, carrying the details it edits.
struct SpaceSettingsItem: Identifiable {
    let id: String
    let details: RoomDetails
}

/// Identifies a space the user is inviting someone to.
struct SpaceInviteItem: Identifiable {
    let id: String
    let name: String
}

/// Identifies a space the user wants to leave, carrying the children for confirmation.
struct LeaveSpaceItem: Identifiable {
    let id: String
    let name: String
    let children: [LeaveSpaceChild]
}

struct MainView: View { // swiftlint:disable:this type_body_length
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(AppActions.self) private var appActions
    @Environment(\.callManager) private var callManager
    @Environment(\.openWindow) private var openWindow
    /// Survives relaunches. Not bound to the list directly: a `List(selection:)`
    /// driven by `@AppStorage` loses its highlight the moment the mouse is
    /// released, because the value round-trips through `UserDefaults` and the
    /// list's internal selection tracking does not survive the trip. The model
    /// held the right room the whole time — only the highlight dropped.
    @AppStorage("selectedRoomId") private var persistedRoomId: String?

    /// What the list actually binds to.
    @State private var selectedRoomId: String?

    @State private var selectedSpaceId: String?
    @State private var leaveSpaceItem: LeaveSpaceItem?
    @State private var spaceSettingsItem: SpaceSettingsItem?
    @State private var spaceInviteItem: SpaceInviteItem?
    @State private var searchModel: SearchViewModel = SearchViewModel()
    @State private var messageSearchService: (any MessageSearchServiceProtocol)?
    @State private var showingInspector = false
    @State private var showingPinnedMessages = false
    @State private var focusedMessageId: String?
    @State private var incomingVerificationItem: VerificationItem?
    @State private var previewingLinkedRoom: DirectoryRoom?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isJoiningLinkedRoom = false
    @State private var inspectorSelectedProfile: UserProfile?
    @State private var inspectorInitialTab: InspectorTab?
    @State private var isPreparingCall = false
    @State private var showCallConfirmation = false
    /// Whether the call awaiting confirmation will publish video. Set by
    /// whichever of the two toolbar buttons was pressed.
    @State private var pendingCallIsVideo = true

    private var hasOngoingCall: Bool { currentRoom?.hasRoomCall ?? false }
    @State private var showPermissionDeniedAlert = false
    @State private var messageSearchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @Namespace private var toolbarNamespace

    private func scrollToMessage(_ eventId: String) {
        showingPinnedMessages = false
        focusedMessageId = eventId
    }

    private func showUserProfile(_ profile: UserProfile) {
        inspectorSelectedProfile = profile
        showingInspector = true
    }

    @State private var showQuickSwitch = false

    var body: some View {
        navigationContent
        .overlay {
            if showQuickSwitch {
                quickSwitchOverlay
            }
        }
        .onChange(of: appActions.showQuickSwitch) { _, shouldShow in
            if shouldShow {
                appActions.showQuickSwitch = false
                showQuickSwitch = true
            }
        }
    }

    private var quickSwitchOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { showQuickSwitch = false }

            VStack {
                QuickRoomSwitchView(
                    selectedRoomId: $selectedRoomId,
                    isPresented: $showQuickSwitch
                )
                .padding(.top, 80)
                Spacer()
            }
        }
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(
                    min: 110 + spaceRailInset,
                    ideal: 250 + spaceRailInset,
                    max: 310 + spaceRailInset
                )
        } detail: {
            detailContent
                .navigationSplitViewColumnWidth(min: 440, ideal: 540)
                .frame(minHeight: 340)
        }
        .searchable(text: $searchModel.searchText, placement: .sidebar, prompt: "Search\u{2026}")
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) {
            triggerMessageSearch()
        }
        .navigationTitle("")
        .toolbar { windowToolbarContent }
        .onChange(of: searchModel.searchText) {
            if searchModel.isActive {
                triggerMessageSearch()
            } else {
                messageSearchService?.cancel()
                searchModel.messageResults = []
                searchModel.hasMoreMessages = false
            }
        }
        .onChange(of: searchModel.isActive) { _, active in
            if active {
                // Capture the current selection so we can restore it on dismiss.
                if searchModel.previousSelectedRoomId == nil {
                    searchModel.previousSelectedRoomId = selectedRoomId
                }
            } else if let previousId = searchModel.previousSelectedRoomId {
                selectedRoomId = previousId
                searchModel.previousSelectedRoomId = nil
            }
        }
        .onChange(of: appActions.focusSearch) { _, shouldFocus in
            if shouldFocus {
                appActions.focusSearch = false
                isSearchFocused = true
            }
        }
        .onAppear {
            messageSearchService = matrixService.makeMessageSearchService()
        }
        .modifier(SheetModifiers(
            incomingVerificationItem: $incomingVerificationItem,
            previewingLinkedRoom: $previewingLinkedRoom,
            leaveSpaceItem: $leaveSpaceItem,
            spaceSettingsItem: $spaceSettingsItem,
            spaceInviteItem: $spaceInviteItem,
            selectedRoomId: $selectedRoomId,
            appActions: appActions,
            matrixService: matrixService,
            errorReporter: errorReporter,
            isJoiningLinkedRoom: $isJoiningLinkedRoom
        ))
        .sheet(isPresented: Bindable(appActions).showRoomDirectory) {
            RoomDirectoryView(selectedRoomId: $selectedRoomId)
        }
        .onAppear {
            // Restore the room from the last launch into the list's own state.
            if selectedRoomId == nil { selectedRoomId = persistedRoomId }
        }
        .onChange(of: selectedRoomId) { oldRoomId, newRoomId in
            persistedRoomId = newRoomId
            if let oldRoomId {
                matrixService.suspendTimeline(roomId: oldRoomId)
            }
        }
        .onChange(of: selectedSpaceId) {
            if selectedSpaceId != nil {
                selectedRoomId = nil
            }
        }
        .onChange(of: matrixService.spaces.map(\.id)) {
            if let selectedSpaceId, !matrixService.spaces.contains(where: { $0.id == selectedSpaceId }) {
                self.selectedSpaceId = nil
            }
        }
        .onChange(of: matrixService.pendingDeepLink) { _, deepLink in
            guard let deepLink else { return }
            handleDeepLink(deepLink)
        }
        .onAppear {
            if let deepLink = matrixService.pendingDeepLink {
                handleDeepLink(deepLink)
            }
        }
        .alert(
            "Microphone & Camera Access",
            isPresented: $showPermissionDeniedAlert
        ) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Plic needs microphone and camera access to make calls. Grant access in System Settings \u{203A} Privacy & Security.")
        }
        // On the window content, not on the toolbar buttons that raise it: a
        // confirmation attached to a toolbar item cannot be dismissed on
        // macOS 27, and came back on every Cancel until the app was quit.
        .confirmationDialog(
            hasOngoingCall ? "Join Call" : "Start Call",
            isPresented: $showCallConfirmation
        ) {
            Button(hasOngoingCall ? "Join" : "Call") {
                if let roomId = selectedRoomId {
                    startCall(roomId: roomId, video: pendingCallIsVideo)
                }
            }
        } message: {
            if let name = currentRoom?.name {
                Text(hasOngoingCall ? "Join the call in \(name)?" : "Start a call in \(name)?")
            } else {
                Text(hasOngoingCall ? "Join the call in this room?" : "Start a call in this room?")
            }
        }
    }

    // MARK: - Space Rail

    private var spaceRailView: some View {
        SpaceRail(selectedSpaceId: $selectedSpaceId, onSpaceTapped: {
            selectedRoomId = nil
        }, onCreateSpace: {
            appActions.showCreateSpace = true
        }, onLeaveSpace: { space in
            Task {
                do {
                    let children = try await matrixService.leaveSpace(spaceId: space.id)
                    leaveSpaceItem = LeaveSpaceItem(
                        id: space.id,
                        name: space.name,
                        children: children
                    )
                } catch {
                    errorReporter.report(.roomLeaveFailed(error.localizedDescription))
                }
            }
        }, onOpenSettings: { space in
            // The sheet edits a RoomDetails snapshot, so fetch it before
            // presenting rather than showing an empty form that fills in.
            Task {
                guard let details = await matrixService.roomDetails(roomId: space.id) else {
                    errorReporter.report(.roomNotFound(space.name))
                    return
                }
                spaceSettingsItem = SpaceSettingsItem(id: space.id, details: details)
            }
        }, onInvite: { space in
            spaceInviteItem = SpaceInviteItem(id: space.id, name: space.name)
        })
    }

    // MARK: - Sidebar

    /// Extra width the sidebar column needs when the space rail is visible.
    private var spaceRailInset: CGFloat {
        matrixService.spaces.isEmpty ? 0 : SpaceRail.width
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        Group {
            if searchModel.isActive {
                SearchResultsList(
                    rooms: searchModel.filteredRooms(from: matrixService.rooms, spaceId: selectedSpaceId),
                    searchModel: searchModel,
                    selectedRoomId: $selectedRoomId,
                    onLoadMoreMessages: loadMoreMessageResults,
                    onMessageSelected: { roomId, eventId in
                        searchModel.dismiss()
                        isSearchFocused = false
                        selectedRoomId = roomId
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            focusedMessageId = eventId
                        }
                    }
                )
            } else {
                RoomListView(
                    selectedRoomId: $selectedRoomId,
                    selectedSpaceId: $selectedSpaceId
                )
            }
        }
        .environment(\.hasSpaceRail, !matrixService.spaces.isEmpty)
        .safeAreaInset(edge: .leading, spacing: 0) {
            if !matrixService.spaces.isEmpty {
                spaceRailView
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let selectedRoomId, let summary = currentRoom, summary.isInvited, summary.isSpace {
            SpaceInvitePreview(
                invite: summary,
                onAccept: { acceptInvite(summary) },
                onDecline: { declineInvite(summary) }
            )
        } else if let selectedRoomId, let summary = currentRoom, summary.isInvited {
            RoomPreviewView(
                room: DirectoryRoom(
                    roomId: summary.id,
                    name: summary.name,
                    topic: summary.topic,
                    alias: summary.canonicalAlias,
                    avatarURL: summary.avatarURL
                ),
                onJoin: { acceptInvite(summary) },
                onClose: { self.selectedRoomId = nil },
                inviterName: summary.inviterName,
                inviterAvatarURL: summary.inviterAvatarURL,
                onDecline: { declineInvite(summary) },
                showsHeader: false
            )
        } else if let selectedRoomId,
                  let summary = currentRoom, !summary.isInvited,
                  let viewModel = matrixService.makeTimelineViewModel(roomId: selectedRoomId) {
            TimelineView(
                roomId: selectedRoomId,
                roomName: summary.name,
                roomAvatarURL: summary.avatarURL,
                viewModel: viewModel,
                focusedMessageId: $focusedMessageId,
                onUserTap: { profile in showUserProfile(profile) },
                onRoomTap: { identifier in handleRoomTap(identifier) }
            )
            .id(selectedRoomId)
            .inspector(isPresented: $showingInspector) {
                inspectorPanel(roomId: selectedRoomId)
                    .id(selectedRoomId)
                    .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
            }
        } else if let selectedSpaceId,
                  let spaceSummary = matrixService.spaces.first(where: { $0.id == selectedSpaceId }) {
            SpaceDetailView(
                spaceId: selectedSpaceId,
                spaceSummary: spaceSummary,
                selectedRoomId: $selectedRoomId,
                onOpenSettings: {
                    inspectorInitialTab = .general
                    showingInspector.toggle()
                }
            )
            .inspector(isPresented: $showingInspector) {
                spaceInspectorPanel(spaceId: selectedSpaceId)
                    .id(selectedSpaceId)
                    .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
            }
        } else {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pick a room from the sidebar to start chatting.")
            )
        }
    }

    // MARK: - Toolbar

    private var currentRoom: RoomSummary? {
        if selectedRoomId != nil, let room = matrixService.rooms.first(
            where: { $0.id == selectedRoomId
            }) {
            room
        } else {
            nil
        }
    }

    @ToolbarContentBuilder
    private var windowToolbarContent: some ToolbarContent {
        if let selectedRoomId, let room = currentRoom, room.isInvited {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    self.selectedRoomId = nil
                }
                .help("Back to Room List")
            }
            ToolbarItem(placement: .secondaryAction) {
                inviteToolbarCapsule(for: room)
            }
        } else if let selectedRoomId, currentRoom != nil {
            ToolbarItem(placement: .secondaryAction) {
                toolbarTitleCapsule
            }

            ToolbarItem(placement: .primaryAction) {
                startCallButton(roomId: selectedRoomId)
            }
        }
    }

    /// Separate audio and video call buttons, as Element X presents them.
    ///
    /// One button that always published video meant no way to place a voice
    /// call, which is the common case on a laptop.
    private func startCallButton(roomId: String) -> some View {
        let hasOngoingCall = currentRoom?.hasRoomCall ?? false

        return HStack(spacing: 2) {
            callButton(
                label: hasOngoingCall ? "Join Call" : "Voice Call",
                systemImage: "phone.fill",
                video: false,
                highlighted: hasOngoingCall
            )
            callButton(
                label: hasOngoingCall ? "Join with Video" : "Video Call",
                systemImage: "video.fill",
                video: true,
                highlighted: hasOngoingCall
            )
        }
    }

    /// One of the two call buttons.
    ///
    /// - Parameters:
    ///   - label: Help text and accessibility label.
    ///   - systemImage: The SF Symbol to draw.
    ///   - video: Whether pressing this starts a call that publishes video.
    ///   - highlighted: Whether a call is already running in the room, which
    ///     forces the title to render alongside the icon. The default macOS
    ///     toolbar style hides titles, leaving the pill indistinguishable from
    ///     its idle state.
    private func callButton(
        label: String,
        systemImage: String,
        video: Bool,
        highlighted: Bool
    ) -> some View {
        Button {
            pendingCallIsVideo = video
            showCallConfirmation = true
        } label: {
            if highlighted {
                Label(label, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
            } else {
                Label(label, systemImage: systemImage)
            }
        }
        .help(label)
        .accessibilityLabel(label)
        .disabled(callManager.hasActiveCall)
    }

    private var toolbarTitleCapsule: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    showingInspector.toggle()
                } label: {
                    ToolbarRoomLabel(
                        room: currentRoom,
                        showingInspector: showingInspector
                    )
                }
                .help(showingInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
    }

    private func inviteToolbarCapsule(for invite: RoomSummary) -> some View {
        HStack(spacing: 0) {
            AvatarView(name: invite.name,
                       mxcURL: invite.avatarURL,
                       size: 28)
            .padding(.leading, 4)
            Text(invite.name)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Call Handling

    private func startCall(roomId: String, video: Bool) {
        guard !callManager.hasActiveCall else { return }

        Task {
            // If the user has previously denied access to something this call
            // needs, show an alert directing them to System Settings rather
            // than starting a call that will immediately fail. A voice call
            // does not consult the camera permission.
            if MediaPermissions.isDenied(video: video) {
                showPermissionDeniedAlert = true
                return
            }

            callManager.isPreparingCredentials = true
            callManager.callRoomId = roomId

            guard let viewModel = await matrixService.makeCallViewModel(roomId: roomId) else {
                callManager.isPreparingCredentials = false
                callManager.callRoomId = nil
                return
            }

            // Defer the observable state change + window open to the next
            // run-loop iteration. Setting activeCallViewModel invalidates
            // the CallWindowView body across window boundaries; if that
            // fires during an active layout pass the recursive constraint
            // update crash occurs.
            let openWindowAction = openWindow
            DispatchQueue.main.async {
                callManager.activeCallViewModel = viewModel
                openWindowAction(id: "call")
            }

            do {
                let creds = try await matrixService.callCredentials(for: roomId)
                try await viewModel.connect(
                    url: creds.livekitURL,
                    token: creds.token,
                    sfuServiceURL: creds.sfuServiceURL,
                    video: video
                )
                callManager.isPreparingCredentials = false
            } catch {
                // Surface the failure and fully tear down the call so the
                // toolbar call button (disabled while `hasActiveCall`) is
                // re-enabled. Without this the failed view model stays set
                // and the button is stuck disabled until the app restarts —
                // the `.failed` overlay's Dismiss is the only other path and
                // its window is easily missed behind the main window.
                errorReporter.report(.callFailed(error.localizedDescription))
                await callManager.endCall()
            }
        }
    }

    // MARK: - Deep Link Handling

    /// Handles an incoming ``MatrixURI`` deep link by navigating to the referenced entity.
    private func handleDeepLink(_ uri: MatrixURI) {
        matrixService.pendingDeepLink = nil

        switch uri {
        case .room(let alias, _), .roomId(let alias, _):
            handleRoomTap(alias)
        case .user(let userId):
            let profile = UserProfile(userId: userId)
            showUserProfile(profile)
        case .event(let roomId, _, _):
            handleRoomTap(roomId)
        }
    }

    // MARK: - Room Link Handling

    /// Handles a tap on a `matrix.to` room link.
    ///
    /// If the user is already a member of the room, the sidebar selection
    /// navigates to it directly. Otherwise a room preview sheet is shown.
    private func handleRoomTap(_ identifier: String) {
        // Check if the user is already a member by room ID or canonical alias.
        if let joined = matrixService.rooms.first(where: {
            $0.id == identifier || $0.canonicalAlias == identifier
        }) {
            selectedRoomId = joined.id
            return
        }

        // Not a member -- show the room preview.
        let room: DirectoryRoom
        if identifier.hasPrefix("#") {
            room = DirectoryRoom(roomId: identifier, alias: identifier)
        } else {
            room = DirectoryRoom(roomId: identifier)
        }
        previewingLinkedRoom = room
    }

    /// Joins a room opened from a `matrix.to` link and navigates to it.
    private func joinLinkedRoom(_ room: DirectoryRoom) {
        guard !isJoiningLinkedRoom else { return }
        isJoiningLinkedRoom = true

        Task {
            do {
                let idOrAlias = room.alias ?? room.roomId
                try await matrixService.joinRoom(idOrAlias: idOrAlias)

                // Wait briefly for the room list to sync.
                try? await Task.sleep(for: .milliseconds(500))
                if let joined = matrixService.rooms.first(where: {
                    $0.id == room.roomId
                }) {
                    selectedRoomId = joined.id
                }
                previewingLinkedRoom = nil
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isJoiningLinkedRoom = false
        }
    }

    // MARK: - Invite Actions

    /// Accepts an invitation and keeps the room selected so the detail
    /// transitions from the invite preview to the timeline once the
    /// membership changes to `.joined`.
    private func acceptInvite(_ invite: RoomSummary) {
        Task {
            do {
                try await matrixService.acceptInvite(roomId: invite.id)
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    /// Declines an invitation and deselects the room.
    private func declineInvite(_ invite: RoomSummary) {
        selectedRoomId = nil
        Task {
            do {
                try await matrixService.declineInvite(roomId: invite.id)
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Message Search

    private func triggerMessageSearch() {
        messageSearchTask?.cancel()
        let term = searchModel.searchText.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, let service = messageSearchService else {
            searchModel.messageResults = []
            searchModel.hasMoreMessages = false
            searchModel.isSearchingMessages = false
            return
        }

        searchModel.isSearchingMessages = true
        messageSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try await service.search(term: term, filter: nil)
                // A keystroke landing mid-request supersedes this one; its task
                // owns the results and the spinner from here.
                guard !Task.isCancelled else { return }
                searchModel.messageResults = service.results
                searchModel.hasMoreMessages = service.hasMore
            } catch is CancellationError {
                return
            } catch let relayError as RelayError {
                // Already worded for a person: the search service translates the
                // SDK's Rust debug dumps before they get this far.
                guard !Task.isCancelled else { return }
                errorReporter.report(relayError)
            } catch {
                // The SDK does not always surface cancellation as
                // `CancellationError` — it threw a plain error whose message was
                // "cancelled", which the old code showed as "Search Failed".
                // Every keystroke raised an alert. Check the task instead of
                // trusting the error type.
                guard !Task.isCancelled else { return }
                errorReporter.report(.searchFailed(error.localizedDescription))
            }
            searchModel.isSearchingMessages = false
        }
    }

    private func loadMoreMessageResults() {
        guard let service = messageSearchService, service.hasMore, !searchModel.isSearchingMessages else { return }
        searchModel.isSearchingMessages = true
        messageSearchTask = Task {
            do {
                try await service.loadMore()
                guard !Task.isCancelled else { return }
                searchModel.messageResults = service.results
                searchModel.hasMoreMessages = service.hasMore
            } catch is CancellationError {
                return
            } catch let relayError as RelayError {
                guard !Task.isCancelled else { return }
                errorReporter.report(relayError)
            } catch {
                guard !Task.isCancelled else { return }
                errorReporter.report(.searchFailed(error.localizedDescription))
            }
            searchModel.isSearchingMessages = false
        }
    }

    // MARK: - Inspector Panel

    private func dismissInspector() {
        showingInspector = false
    }

    private func inspectorPanel(roomId: String) -> some View {
        TimelineInspectorView(
            roomId: roomId,
            context: .room,
            selectedProfile: $inspectorSelectedProfile,
            onMessageUser: { userId in
                Task {
                    do {
                        let dmRoomId = try await matrixService.createDirectMessage(userId: userId)
                        selectedRoomId = dmRoomId
                        showingInspector = false
                    } catch {
                        errorReporter.report(.dmCreationFailed(error.localizedDescription))
                    }
                }
            },
            onScrollToMessage: scrollToMessage
        )
    }

    private func spaceInspectorPanel(spaceId: String) -> some View {
        TimelineInspectorView(
            roomId: spaceId,
            context: .space,
            initialTab: $inspectorInitialTab,
            onMessageUser: { userId in
                Task {
                    do {
                        let dmRoomId = try await matrixService.createDirectMessage(userId: userId)
                        selectedRoomId = dmRoomId
                        showingInspector = false
                    } catch {
                        errorReporter.report(.dmCreationFailed(error.localizedDescription))
                    }
                }
            }
        )
    }
}

// MARK: - Sheet Modifiers

/// Groups sheet presentations to reduce the complexity of ``MainView/body``.
private struct SheetModifiers: ViewModifier {
    @Binding var incomingVerificationItem: VerificationItem?
    @Binding var previewingLinkedRoom: DirectoryRoom?
    @Binding var leaveSpaceItem: LeaveSpaceItem?
    @Binding var spaceSettingsItem: SpaceSettingsItem?
    @Binding var spaceInviteItem: SpaceInviteItem?
    @Binding var selectedRoomId: String?
    let appActions: AppActions
    let matrixService: any MatrixServiceProtocol
    let errorReporter: ErrorReporter
    @Binding var isJoiningLinkedRoom: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: matrixService.shouldPresentVerificationSheet) { _, shouldPresent in
                guard shouldPresent else { return }
                matrixService.shouldPresentVerificationSheet = false
                Task {
                    // swiftlint:disable:next identifier_name
                    if let vm = try? await matrixService.makeSessionVerificationViewModel(acceptingIncomingRequest: true) {
                        matrixService.pendingVerificationRequest = nil
                        incomingVerificationItem = VerificationItem(viewModel: vm)
                    }
                }
            }
            .sheet(item: $incomingVerificationItem) { item in
                VerificationSheet(viewModel: item.viewModel)
            }
            .sheet(isPresented: Bindable(appActions).showCreateRoom) {
                CreateEntitySheet(kind: .room, selectedRoomId: $selectedRoomId)
            }
            .sheet(isPresented: Bindable(appActions).showCreateSpace) {
                CreateEntitySheet(kind: .space)
            }
            .sheet(isPresented: Bindable(appActions).showJoinRoom) {
                JoinRoomSheet(selectedRoomId: $selectedRoomId)
            }
            .sheet(item: $previewingLinkedRoom) { room in
                RoomPreviewView(
                    room: room,
                    onJoin: { joinLinkedRoom(room) },
                    onClose: { previewingLinkedRoom = nil }
                )
                .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 500)
            }
            .sheet(item: $leaveSpaceItem) { item in
                LeaveSpaceSheet(spaceName: item.name, spaceId: item.id, children: item.children)
            }
            .sheet(item: $spaceSettingsItem) { item in
                SpaceSettingsSheet(spaceId: item.id, details: item.details)
            }
            .sheet(item: $spaceInviteItem) { item in
                InviteToSpaceSheet(spaceId: item.id, spaceName: item.name)
            }
    }

    private func joinLinkedRoom(_ room: DirectoryRoom) {
        guard !isJoiningLinkedRoom else { return }
        isJoiningLinkedRoom = true

        Task {
            do {
                let idOrAlias = room.alias ?? room.roomId
                try await matrixService.joinRoom(idOrAlias: idOrAlias)

                try? await Task.sleep(for: .milliseconds(500))
                if let joined = matrixService.rooms.first(where: {
                    $0.id == room.roomId
                }) {
                    selectedRoomId = joined.id
                }
                previewingLinkedRoom = nil
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isJoiningLinkedRoom = false
        }
    }
}

/// The label content for the room title toolbar capsule.
///
/// Reads `controlSize` from the environment to shrink the avatar when
/// rendered inside the toolbar overflow menu.
private struct ToolbarRoomLabel: View {
    let room: RoomSummary?
    let showingInspector: Bool

    @Environment(\.controlSize) private var controlSize

    private var avatarSize: CGFloat {
        controlSize == .regular ? 28 : 16
    }

    var body: some View {
        HStack(spacing: 0) {
            if let room {
                AvatarView(name: room.name,
                           mxcURL: room.avatarURL,
                           size: avatarSize)
                .fixedSize()
                Text(room.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .truncationMode(.tail)
                    .frame(maxWidth: 100)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                Image(systemName: showingInspector ? "xmark" : "chevron.right")
                    .font(.system(size: 12, weight: showingInspector ? .bold : .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.capsule)
    }
}

#Preview {
    MainView()
        .environment(\.matrixService, PreviewMatrixService())
        .environment(AppActions())
        .frame(width: 900, height: 600)
}
