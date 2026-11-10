// Copyright 2026 Denis Florent Media Group SRL
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

/// Picks the room a message is forwarded to.
struct ForwardMessageSheet: View {
    let message: TimelineMessage
    let fromRoomId: String

    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isSending = false
    @FocusState private var isFieldFocused: Bool

    private var rooms: [RoomSummary] {
        let joined = matrixService.rooms.filter { !$0.isSpace && $0.membership == .joined }
        let term = query.trimmingCharacters(in: .whitespaces)
        let matching = term.isEmpty ? joined : joined.filter { $0.name.localizedStandardContains(term) }
        return matching.sorted { ($0.lastMessageTimestamp ?? .distantPast) > ($1.lastMessageTimestamp ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Forward To")
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {}
                    .hidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Room", text: $query, prompt: Text("Find a room"))
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            List(rooms) { room in
                Button {
                    forward(to: room)
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(name: room.name, mxcURL: room.avatarURL, size: 28, colorID: room.id)
                        Text(room.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if room.id == fromRoomId {
                            Text("This room")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .disabled(isSending)
        }
        .frame(width: 440, height: 460)
        .onAppear { isFieldFocused = true }
    }

    private func forward(to room: RoomSummary) {
        guard !isSending else { return }
        isSending = true
        Task {
            do {
                try await matrixService.forwardMessage(eventId: message.eventID, from: fromRoomId, to: room.id)
                dismiss()
            } catch {
                errorReporter.report(.messageSendFailed(error.localizedDescription))
                isSending = false
            }
        }
    }
}
