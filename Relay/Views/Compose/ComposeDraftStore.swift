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

import SwiftUI

/// Caches ``ComposeViewModel`` instances per room so unsent drafts survive room switches.
///
/// When the user navigates away from a room, the ``TimelineView`` is destroyed
/// (due to its `.id(selectedRoomId)` modifier) and any unsent compose state
/// would normally be lost. ``ComposeDraftStore`` retains each room's compose
/// view model in memory, restoring the full draft (text, reply/edit context,
/// staged attachments, and mentions) when the user returns.
///
/// The store lives for the app session. Drafts are not persisted across app
/// restarts.
@MainActor
final class ComposeDraftStore {
    private var drafts: [String: ComposeViewModel] = [:]

    /// Returns the compose view model for a room, creating one if needed.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: The cached or newly created ``ComposeViewModel``.
    func draft(for roomId: String) -> ComposeViewModel {
        if let existing = drafts[roomId] {
            return existing
        }
        let viewModel = ComposeViewModel()
        drafts[roomId] = viewModel
        return viewModel
    }

    /// Discards every draft.
    ///
    /// Called on sign-out. Drafts are keyed by room alone, so one left behind
    /// would outlive the session that typed it and reappear for whoever signs
    /// in next, in any room they share.
    func removeAll() {
        for draft in drafts.values {
            draft.discardAttachments()
        }
        drafts.removeAll()
    }
}

// MARK: - Environment Key

private struct ComposeDraftStoreKey: EnvironmentKey {
    static let defaultValue = ComposeDraftStore()
}

extension EnvironmentValues {
    /// The shared compose draft store used to preserve unsent messages across room switches.
    var composeDraftStore: ComposeDraftStore {
        get { self[ComposeDraftStoreKey.self] }
        set { self[ComposeDraftStoreKey.self] = newValue }
    }
}
