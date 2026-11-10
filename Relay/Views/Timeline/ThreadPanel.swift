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

/// A thread, shown beside the room in the inspector column: its replies,
/// and a compose bar that answers into it.
struct ThreadPanel: View {
    let roomId: String
    let rootEventId: String
    let onClose: () -> Void

    @Environment(\.matrixService) private var matrixService
    @State private var viewModel: (any TimelineViewModelProtocol)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Thread", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)
                Spacer()
                Button("Close Thread", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close Thread")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let viewModel {
                TimelineView(
                    roomId: roomId,
                    roomName: "Thread",
                    viewModel: viewModel,
                    focusedMessageId: .constant(nil),
                    threadRootEventId: rootEventId
                )
                .id(rootEventId)
            } else {
                Spacer()
            }
        }
        .task(id: rootEventId) {
            // One view model per thread, kept for as long as the panel shows it.
            viewModel = matrixService.makeThreadTimelineViewModel(roomId: roomId)
        }
    }
}
