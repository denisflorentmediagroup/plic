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


import SwiftUI

/// Under the user's own message: who has read this far, as Messages shows
/// "Read". Names are the user IDs' local parts; the full IDs are in the
/// tooltip.
struct SeenByLabel: View {
    let userIds: [String]

    private var text: String {
        let names = userIds.map { id -> String in
            let local = id.dropFirst().split(separator: ":").first.map(String.init) ?? id
            return local
        }
        switch names.count {
        case 1: return "Seen by \(names[0])"
        case 2: return "Seen by \(names[0]) and \(names[1])"
        default: return "Seen by \(names[0]) and \(names.count - 1) others"
        }
    }

    var body: some View {
        Text(text)
            .scaledChromeFont(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .help(userIds.joined(separator: "\n"))
            .accessibilityLabel(text)
    }
}
