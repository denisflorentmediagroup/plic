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

/// Under a message that started a thread: how many replies it has, and
/// who wrote the last one. Opens the thread.
struct ThreadSummaryButton: View {
    let summary: TimelineMessage.ThreadSummary
    let isOutgoing: Bool
    let open: () -> Void

    private var title: String {
        summary.replyCount == 1 ? "1 reply" : "\(summary.replyCount) replies"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .accessibilityHidden(true)
                Text(title)
                    .bold()
                if let name = summary.latestSenderName {
                    Text("· last from \(name)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .scaledChromeFont(.caption1)
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("\(title) in thread")
        .accessibilityHint("Opens the thread")
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
}
