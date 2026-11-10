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


import AppKit

/// Rings for an incoming call: a system sound a few times over, stopped
/// when the user answers or the ringing has gone on long enough.
///
/// Only direct chats ring. A call starting in a group room is announced
/// by its notification alone; a bell for every stand-up would be noise.
@MainActor
final class CallRinger {
    static let shared = CallRinger()

    private var ringTask: Task<Void, Never>?
    private let sound = NSSound(named: "Glass")

    /// How many times the sound plays, two seconds apart.
    private static let rings = 4

    func start() {
        guard ringTask == nil else { return }
        ringTask = Task {
            for _ in 0..<Self.rings {
                guard !Task.isCancelled else { break }
                sound?.stop()
                sound?.play()
                try? await Task.sleep(for: .seconds(2))
            }
            ringTask = nil
        }
    }

    func stop() {
        ringTask?.cancel()
        ringTask = nil
        sound?.stop()
    }
}
