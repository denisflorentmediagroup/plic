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

/// Ordered contextual-menu sections for a timeline bubble (SwiftUI + NSTextView).
enum TimelineMessageContextMenuEntry: Equatable {
    case reply
    case replyInThread
    case copyMessage
    case saveMedia
    case addReaction
    case togglePin
    case edit
    case separatorBeforeReport
    case report
    case separatorBeforeDelete
    case delete
}

enum TimelineMessageContextMenu {
    /// Entries shown for a normal (non-system) timeline message row.
    ///
    /// - Parameters:
    ///   - message: The timeline message to build context menu entries for.
    ///   - permissions: The current user's room-level permissions. When `nil`
    ///     (e.g. in previews), actions default to standard user capabilities.
    static func entries(
        for message: TimelineMessage,
        permissions: RoomPermissions? = nil,
        inThread: Bool = false
    ) -> [TimelineMessageContextMenuEntry] {
        let canSend = permissions?.canSendMessages ?? true

        var result: [TimelineMessageContextMenuEntry] = [.copyMessage]
        if message.mediaInfo != nil {
            result.append(.saveMedia)
        }
        if canSend {
            result.insert(.reply, at: 0)
            // A thread grows from a sent message; a reply in one is already
            // in its thread, and a local echo has no ID to root one on.
            if inThread == false, message.eventID.hasPrefix("$") {
                result.insert(.replyInThread, at: 1)
            }
            result.append(.addReaction)
        }
        if (permissions?.canPin ?? false) && message.eventID.hasPrefix("$") {
            result.append(.togglePin)
        }
        if message.isOutgoing && message.kind == .text && canSend {
            result.append(.edit)
        }
        // Reporting your own message is meaningless, and a redacted one has
        // nothing left to report. Everything else is reportable — App Store
        // guideline 1.2 requires a reporting path for user-generated content,
        // and a client that federates with arbitrary servers needs one anyway.
        if !message.isOutgoing && message.kind != .redacted && message.eventID.hasPrefix("$") {
            result.append(.separatorBeforeReport)
            result.append(.report)
        }
        if (message.isOutgoing || (permissions?.canRedactOther ?? false))
            && message.kind != .redacted {
            result.append(.separatorBeforeDelete)
            result.append(.delete)
        }
        return result
    }
}

/// Actions that timeline rows request via ``TimelineRowView/onContextAction``.
enum TimelineRowContextAction {
    case reply(TimelineMessage)
    case replyInThread(TimelineMessage)
    case copy(String)
    case saveMedia(TimelineMessage)
    case togglePin(String)
    case edit(TimelineMessage)
    case report(TimelineMessage)
    case delete(TimelineMessage)
}
