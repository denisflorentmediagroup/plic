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

/// Displays compact emoji reaction badges that overlay the top corner of a
/// message bubble, styled after iMessage.
///
/// When collapsed (default), badges overlap horizontally. On hover they fan out
/// to reveal each reaction individually. Each badge is a small circle containing
/// the emoji, with an optional count indicator and an accent-color border when
/// the current user has sent that reaction.
struct MessageReactionBadges: View {
    let reactions: [TimelineMessage.ReactionGroup]

    /// Whether the message is outgoing (determines fan-out direction).
    let isOutgoing: Bool

    /// Whether colored bubbles are enabled (determines badge fill color).
    let coloredBubbles: Bool

    /// Called with the emoji key when the user taps a badge.
    let onToggle: (String) -> Void

    /// The diameter of each reaction badge circle.
    private static let badgeSize: CGFloat = 22

    /// The horizontal offset between overlapping badges when collapsed.
    private static let collapsedStep: CGFloat = -12

    /// The horizontal spacing between badges when fanned out on hover.
    private static let expandedStep: CGFloat = 2

    /// Scale factor applied to the badge group on hover.
    private static let hoverScale: CGFloat = 1.25

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let step = isHovering ? Self.expandedStep : Self.collapsedStep

        // The visible badge stack.
        HStack(spacing: 0) {
            ForEach(
                isOutgoing ? reactions.reversed().enumerated() : reactions.enumerated(),
                id: \.element.id
            ) { index, reaction in
                ReactionBadge(
                    reaction: reaction,
                    coloredBubbles: coloredBubbles,
                    onToggle: { onToggle(reaction.key) }
                )
                .offset(
                    x: offsetForIndex(
                        isOutgoing ? index : reactions.count - index,
                        step: step
                    )
                )
                .zIndex(Double(reactions.count - index))
            }
        }
        // The total width of the stack needs to account for overlapping badges.
        .frame(
            width: totalWidth(step: step),
            height: Self.badgeSize,
            alignment: isOutgoing ? .leading : .trailing
        )
        .scaleEffect(isHovering ? Self.hoverScale : 1.0)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) {
                isHovering = hovering
            }
        }
    }

    private func offsetForIndex(_ index: Int, step: CGFloat) -> CGFloat {
        // Outgoing badges are at top-leading, fan rightward (positive).
        // Incoming badges are at top-trailing, fan leftward (negative).
        // A single reaction does not fan at all.
        if reactions.count == 1 { return 0.0 }
        let direction: CGFloat = isOutgoing ? 1 : -1
        return CGFloat(index) * step * direction
    }

    private func totalWidth(step: CGFloat) -> CGFloat {
        guard reactions.count > 1 else { return Self.badgeSize }
        return max(Self.badgeSize + CGFloat(reactions.count - 1) * step, Self.badgeSize)
    }
}

/// A single reaction badge: emoji in a small circle with optional count and border.
///
/// When colored bubbles are enabled, the circle fill color is derived from the
/// first sender of this reaction via ``Color/init(stableColorFor:)``, so each reactor gets
/// their own color. Otherwise a neutral gray is used.
private struct ReactionBadge: View {
    let reaction: TimelineMessage.ReactionGroup
    let coloredBubbles: Bool
    let onToggle: () -> Void

    private static let size: CGFloat = 22

    private var fillColor: Color {
        if coloredBubbles, let firstSender = reaction.senderIDs.first {
            return Color(stableColorFor: firstSender)
        }
        return Color(.accent)
    }

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(reaction.highlightedByCurrentUser ? fillColor : .clear)
                    .frame(width: Self.size, height: Self.size)

                Text(reaction.key)
                    .font(.system(size: 12))
            }
            .overlay(alignment: .topTrailing) {
                if reaction.count > 1 {
                    Text("\(reaction.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.secondary, in: Capsule())
                }
            }
        }
        // Who reacted, on hover: the IDs' local parts, as the SDK gives no names here.
        .help(reaction.senderIDs.map { id in
            String(id.dropFirst().split(separator: ":").first ?? Substring(id))
        }.joined(separator: ", "))
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

private let sampleReactions: [TimelineMessage.ReactionGroup] = [
    .init(key: "\u{1F389}", count: 3,
          senderIDs: ["@alice:matrix.org", "@bob:matrix.org", "@charlie:matrix.org"],
          highlightedByCurrentUser: false),
    .init(key: "\u{1F680}", count: 1,
          senderIDs: ["@alice:matrix.org"],
          highlightedByCurrentUser: false),
    .init(key: "\u{1F44D}", count: 2,
          senderIDs: ["@bob:matrix.org", "@me:matrix.org"],
          highlightedByCurrentUser: true),
    .init(key: "\u{1F44E}", count: 1,
          senderIDs: ["@alice:matrix.org"],
          highlightedByCurrentUser: false)
]

#Preview("Outgoing") {
    VStack {
        Text("Check out this new feature!")
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(.rect(cornerRadius: 17))
            .overlay(alignment: .topLeading) {
                MessageReactionBadges(
                    reactions: sampleReactions,
                    isOutgoing: true,
                    coloredBubbles: false,
                    onToggle: { _ in }
                )
                .offset(x: -4, y: -11)
            }
            .padding(.top, 11)
    }
    .padding(40)
}

#Preview("Incoming") {
    VStack {
        Text("Nice, rooms are loading way faster now.")
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.unemphasizedSelectedContentBackgroundColor))
            .clipShape(.rect(cornerRadius: 17))
            .overlay(alignment: .topTrailing) {
                MessageReactionBadges(
                    reactions: sampleReactions,
                    isOutgoing: false,
                    coloredBubbles: false,
                    onToggle: { _ in }
                )
                .offset(x: 4, y: -11)
            }
            .padding(.top, 11)
    }
    .padding(40)
}

#Preview("Single Reaction") {
    VStack {
        Text("Hello!")
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.unemphasizedSelectedContentBackgroundColor))
            .clipShape(.rect(cornerRadius: 17))
            .overlay(alignment: .topTrailing) {
                MessageReactionBadges(
                    reactions: [
                        .init(key: "\u{2764}\u{FE0F}", count: 1,
                              senderIDs: ["@me:matrix.org"],
                              highlightedByCurrentUser: true),
                    ],
                    isOutgoing: false,
                    coloredBubbles: false,
                    onToggle: { _ in }
                )
                .offset(x: 4, y: -11)
            }
            .padding(.top, 11)
    }
    .padding(40)
}

