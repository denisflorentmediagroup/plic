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
import UniformTypeIdentifiers

/// The message composition bar at the bottom of the timeline.
///
/// ``ComposeBar`` presents the text field with inline mention pills,
/// attachment staging, reply/edit banners, and action buttons (attach, emoji).
/// All compose state lives in a ``ComposeViewModel`` passed via `@Bindable`.
struct ComposeBar: View {
    @Bindable var compose: ComposeViewModel

    /// Called when the user submits a message.
    var onSend: () async -> Void

    /// Called when the user stages files (from file picker, drag, or paste).
    var onAttach: ([URL]) -> Void

    /// Starts a poll: question, answers, how many one may pick, whether
    /// results show while it runs.
    var onCreatePoll: (String, [String], Int, Bool) async -> Void = { _, _, _, _ in }

    /// Called when the user finishes recording a voice message.
    var onSendVoice: (VoiceRecorder.Recording) async -> Void

    @Environment(\.errorReporter) private var errorReporter
    @State private var pasteHandler = PasteHandler()
    @State private var mentionSuggestionsHeight: CGFloat = 0
    @State private var recorder = VoiceRecorder()

    @AppStorage(ConversationGround.BarShadow.key)
    private var barShadowOpacity = ConversationGround.BarShadow.standard

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.isEncoding {
                    encodingStrip
                } else if recorder.isRecording {
                    recordingStrip
                } else {
                    composeContent
                    actionButtons
                }
            }
        }
        // On the container rather than its parts, so the field and the buttons
        // cast one shadow and each glass shape keeps its own outline.
        .shadow(
            color: .black.opacity(barShadowOpacity),
            radius: ConversationGround.BarShadow.radius,
            y: ConversationGround.BarShadow.yOffset
        )
        .animation(.easeOut(duration: 0.15), value: recorder.isRecording)
        .animation(.easeOut(duration: 0.15), value: recorder.isEncoding)
        .animation(.easeOut(duration: 0.15), value: compose.mentionQuery != nil)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: compose.replyingTo != nil)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: compose.editingMessage != nil)
        .sheet(isPresented: $compose.isShowingPollComposer) {
            PollComposerSheet { question, answers, maxSelections, isDisclosed in
                await onCreatePoll(question, answers, maxSelections, isDisclosed)
            }
        }
        .fileImporter(
            isPresented: $compose.isShowingFilePicker,
            allowedContentTypes: ComposeViewModel.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
            }
        }
        .onDrop(
            of: ComposeViewModel.dropTypes,
            isTargeted: Binding(
                get: { compose.isDropTargeted },
                set: { targeted in
                    withAnimation(.easeOut(duration: 0.15)) {
                        compose.isDropTargeted = targeted
                    }
                }
            )
        ) { providers in
            guard !providers.isEmpty else { return false }
            compose.handleDropProviders(providers, errorReporter: errorReporter)
            return true
        }
        .onAppear { pasteHandler.startMonitoring() }
        .onDisappear { pasteHandler.stopMonitoring() }
        .onChange(of: pasteHandler.pastedURLs) { _, urls in
            guard let urls else { return }
            pasteHandler.pastedURLs = nil
            onAttach(urls)
        }
        .onChange(of: compose.mentionQuery) {
            compose.mentionSelectedIndex = 0
        }
    }

    // MARK: - Compose Content

    private var composeContent: some View {
        ComposeBarContent(
            compose: compose,
            mentionSuggestionsHeight: $mentionSuggestionsHeight,
            onSend: onSend
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        ComposeBarActions(compose: compose) {
            if !recorder.start() {
                errorReporter.report(
                    .attachmentSendFailed(
                        filename: "voice message",
                        reason: "Could not start recording. Check microphone access in System Settings."
                    )
                )
            }
        }
    }

    // MARK: - Recording

    /// Shown between pressing send and the message appearing in the timeline.
    ///
    /// Encoding a minute of speech takes a moment, and without this the app
    /// simply looked stalled. Reuses the audio bubble's shape so it reads as the
    /// message being prepared, with the waveform filling left to right against
    /// real encoder progress rather than an indeterminate spinner.
    private var encodingStrip: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Encoding…")
                    .font(.callout)
                    .fontWeight(.medium)

                WaveformView(
                    amplitudes: recorder.levels,
                    progress: recorder.encodingProgress,
                    usesWhiteText: false,
                    onSeek: { _ in }
                )
                .frame(height: 22)
            }

            Spacer(minLength: 0)

            Text(recorder.duration.formattedDuration)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Encoding voice message")
        .accessibilityValue("\(Int(recorder.encodingProgress * 100)) percent")
    }

    /// Replaces the whole compose row while a voice message is being recorded.
    ///
    /// Takes over rather than sitting alongside the text field: the two actions
    /// are mutually exclusive, and a live waveform needs the width.
    private var recordingStrip: some View {
        HStack(spacing: 10) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Discard recording")

            // All bars accent-coloured: during capture there is no played and
            // unplayed portion, only what has been heard so far.
            WaveformView(
                amplitudes: recorder.levels.suffix(60).map { $0 },
                progress: 1,
                usesWhiteText: false,
                onSeek: { _ in }
            )
            .frame(height: 24)
            .frame(maxWidth: .infinity)

            Text(recorder.duration.formattedDuration)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                Task {
                    if let recording = await recorder.finish() {
                        await onSendVoice(recording)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Send voice message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 20))
    }
}

/// The main content area of the compose bar (text field, banners, attachments, mention suggestions).
private struct ComposeBarContent: View {
    @Bindable var compose: ComposeViewModel
    @Binding var mentionSuggestionsHeight: CGFloat
    @State private var textViewHeight: CGFloat = MessageTextScale.baseFontSize * 1.2 + 20
    @AppStorage(ConversationGround.FieldDepth.key)
    private var fieldGroundDepth = ConversationGround.FieldDepth.standard
    var onSend: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compose.attachments.isEmpty {
                AttachmentStagingView(compose: compose)
            }

            if let replyMessage = compose.replyingTo {
                ReplyEditBanner(
                    label: "Replying to \(replyMessage.senderDisplayName ?? replyMessage.senderID)",
                    systemImage: "arrowshape.turn.up.left"
                ) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        compose.cancelReply()
                    }
                }
            }

            if compose.editingMessage != nil {
                ReplyEditBanner(
                    label: "Editing Message",
                    systemImage: "pencil"
                ) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        compose.cancelEdit()
                    }
                }
            }

            ComposeTextView(
                text: $compose.text,
                mentionQuery: $compose.mentionQuery,
                insertMentionHandler: $compose.insertMentionHandler,
                insertTextHandler: $compose.insertTextHandler,
                onSubmit: {
                    if compose.hasContent {
                        Task { await onSend() }
                    }
                },
                onCancel: compose.editingMessage != nil || compose.replyingTo != nil ? {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        if compose.editingMessage != nil {
                            compose.cancelEdit()
                        } else {
                            compose.cancelReply()
                        }
                    }
                } : nil,
                onHeightChange: { textViewHeight = $0 },
                onMentionNavigateUp: {
                    compose.mentionSelectedIndex = max(
                        0, compose.mentionSelectedIndex - 1
                    )
                },
                onMentionNavigateDown: {
                    compose.mentionSelectedIndex += 1
                },
                onMentionConfirm: {
                    return compose.confirmSelectedMention()
                }
            )
            .frame(height: textViewHeight)
            // Snapping between line counts reads as a glitch. A spring with no
            // bounce settles quickly without drawing attention to itself —
            // Signal animates the same transition with the same shape.
            .animation(.spring(response: 0.25, dampingFraction: 1), value: textViewHeight)
        }
        // Tints the field on top of the glass rather than replacing it: at zero
        // the material shows through untouched, and above zero the fill takes
        // over progressively. The shape follows the same corner radius so the
        // tint never escapes the field's outline.
        .background {
            if fieldGroundDepth > 0 {
                ConversationGround(depth: fieldGroundDepth)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: !compose.attachments.isEmpty ? 16 : 20,
                            style: .continuous
                        )
                    )
            }
        }
        .glassEffect(
            in: .rect(cornerRadius: !compose.attachments.isEmpty ? 16 : 20)
        )
        // A hairline so the field reads as somewhere to type. The glass
        // material alone gives no edge, and against a light conversation it
        // was indistinguishable from the bar around it.
        .overlay(
            RoundedRectangle(
                cornerRadius: !compose.attachments.isEmpty ? 16 : 20,
                style: .continuous
            )
            .strokeBorder(.separator, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: !compose.attachments.isEmpty ? 18 : 22,
                style: .continuous
            )
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(-4)
            .opacity(compose.isDropTargeted ? 1 : 0)
        )
        .overlay(alignment: .topLeading) {
            if compose.mentionQuery != nil {
                MentionSuggestionView(compose: compose) { member in
                    compose.selectMention(member)
                }
                .padding(.horizontal, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    mentionSuggestionsHeight = height
                }
                .offset(y: -(mentionSuggestionsHeight + 4))
            }
        }
    }
}

/// The attach and emoji buttons on the right side of the compose bar.
private struct ComposeBarActions: View {
    @Bindable var compose: ComposeViewModel

    /// Called when the user presses the microphone button.
    var onStartRecording: () -> Void

    @Environment(\.recentEmojiStore) private var recentEmojiStore

    var body: some View {
        // A click attaches a file, as before; the menu holds what else can
        // go into a message.
        Menu {
            Button("Attach File…", systemImage: "paperclip") {
                compose.isShowingFilePicker = true
            }
            Button("Create Poll…", systemImage: "chart.bar") {
                compose.isShowingPollComposer = true
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        } primaryAction: {
            compose.isShowingFilePicker = true
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Attach")
        .help("Attach a file; hold for a poll")
        .glassEffect(in: .circle)

        Button(action: onStartRecording) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: .circle)
        .help("Record a voice message")

        Button {
            compose.isShowingEmojiPicker = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: .circle)
        .help("Emoji")
        // Anchored to the button rather than calling orderFrontCharacterPalette
        // directly: the system palette places itself near the insertion point,
        // which puts it beside the text field instead of above the button that
        // opened it, and there is no public API to move it. The capsule's own
        // trailing button still reaches the full system catalogue.
        .popover(isPresented: $compose.isShowingEmojiPicker, arrowEdge: .top) {
            ReactionPickerCapsule { emoji in
                // Insert at the caret rather than appending: the text view keeps
                // its selection while the popover is up, so a mid-sentence caret
                // still gets the emoji in the right place.
                compose.insertTextHandler?(emoji)
                recentEmojiStore.recordUsage(emoji)
                compose.isShowingEmojiPicker = false
            }
            .padding(6)
        }
    }
}

// MARK: - Previews

private let previewMembers: [RoomMemberDetails] = [
    RoomMemberDetails(
        userId: "@alice:matrix.org", displayName: "Alice Smith", role: .administrator
    ),
    RoomMemberDetails(
        userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator
    ),
    RoomMemberDetails(userId: "@charlie:matrix.org", displayName: "Charlie Davis"),
    RoomMemberDetails(userId: "@diana:matrix.org", displayName: "Diana Evans"),
]

#Preview("Empty") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.members = previewMembers
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onSendVoice: { _ in },
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("With Text") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.text = "Hello, world!"
            vm.members = previewMembers
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onSendVoice: { _ in },
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("With Attachments") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.text = "Check these out"
            vm.members = previewMembers
            vm.attachments = [
                StagedAttachment(
                    url: URL(fileURLWithPath: "/tmp/photo.jpg"),
                    filename: "photo.jpg",
                    thumbnail: nil
                ),
                StagedAttachment(
                    url: URL(fileURLWithPath: "/tmp/document.pdf"),
                    filename: "document.pdf",
                    thumbnail: nil,
                    caption: "Project brief"
                ),
            ]
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onSendVoice: { _ in },
    )
    .frame(width: 500)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("With Mention Suggestions") {
    VStack {
        Spacer()
        ComposeBar(
            compose: {
                let vm = ComposeViewModel()
                vm.text = "Hey @ali"
                vm.members = previewMembers
                vm.mentionQuery = "ali"
                return vm
            }(),
            onSend: {},
            onAttach: { _ in },
            onSendVoice: { _ in },
        )
        .frame(width: 400)
    }
    .frame(height: 350)
    .environment(\.matrixService, PreviewMatrixService())
}
