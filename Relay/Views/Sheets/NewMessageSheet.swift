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

/// Starts a direct conversation with someone, found by name or by Matrix ID.
///
/// Until now a conversation could only be started with someone who already
/// shared a room. The homeserver's user directory answers a name with the
/// people it knows; a full `@user:server` ID works whether or not the
/// directory lists them.
struct NewMessageSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.errorReporter) private var errorReporter

    @Binding var selectedRoomId: String?

    @State private var query = ""
    @State private var results: [UserSearchResult] = []
    @State private var isSearching = false
    @State private var isOpening = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// A complete Matrix ID typed by hand, offered even when the directory
    /// does not list it.
    private var typedUserId: String? {
        let id = trimmedQuery
        guard id.hasPrefix("@"), id.contains(":"), id.count > 3,
              !results.contains(where: { $0.userId == id }) else { return nil }
        return id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            resultsList
        }
        .frame(width: 440, height: 420)
        .onAppear { isFieldFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text("New Message")
                .fontWeight(.semibold)
            Spacer()
            // Balances the Cancel button so the title stays centred.
            Button("Cancel") {}
                .hidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Name or Matrix ID", text: $query, prompt: Text("Name or @user:server"))
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .autocorrectionDisabled()
                .onSubmit { openFirst() }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onChange(of: query) { scheduleSearch() }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty && typedUserId == nil {
            ContentUnavailableView {
                Label(trimmedQuery.isEmpty ? "Find Someone" : "No One Found", systemImage: "person.crop.circle")
            } description: {
                Text(trimmedQuery.isEmpty
                     ? "Type a name to search your server's directory, or a full Matrix ID."
                     : "No one by that name in the directory. A full ID, like @name:server, reaches them anyway.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                if let typedUserId {
                    UserResultRow(user: UserSearchResult(userId: typedUserId, displayName: nil, avatarURL: nil)) {
                        open(userId: typedUserId)
                    }
                }
                ForEach(results) { user in
                    UserResultRow(user: user) { open(userId: user.userId) }
                }
            }
            .listStyle(.inset)
            .disabled(isOpening)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let term = trimmedQuery
        guard term.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await matrixService.searchUsers(term: term, limit: 20)) ?? []
            guard !Task.isCancelled else { return }
            results = found.filter { $0.userId != matrixService.userId() }
            isSearching = false
        }
    }

    private func openFirst() {
        if let typedUserId {
            open(userId: typedUserId)
        } else if let first = results.first {
            open(userId: first.userId)
        }
    }

    private func open(userId: String) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            do {
                let roomId = try await matrixService.createDirectMessage(userId: userId)
                selectedRoomId = roomId
                dismiss()
            } catch {
                errorReporter.report(.dmCreationFailed(error.localizedDescription))
                isOpening = false
            }
        }
    }
}

private struct UserResultRow: View {
    let user: UserSearchResult
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AvatarView(name: user.displayName ?? user.userId, mxcURL: user.avatarURL, size: 32, colorID: user.userId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName ?? user.userId)
                        .lineLimit(1)
                    if user.displayName != nil {
                        Text(user.userId)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Starts a conversation")
    }
}
