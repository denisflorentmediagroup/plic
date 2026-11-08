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

/// Tells the user that a member's encryption identity changed, and lets them
/// accept the new one.
///
/// Shown above the timeline, one line per member, until each is accepted.
/// An identity changes when an account is reset — or when a server slips
/// in keys of its own to read the room — so it is never accepted silently.
struct IdentityChangeBanner: View {
    let changes: [IdentityChange]
    let acknowledge: (String) async -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(changes) { change in
                IdentityChangeRow(change: change, acknowledge: acknowledge)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct IdentityChangeRow: View {
    let change: IdentityChange
    let acknowledge: (String) async -> Void
    @State private var isWorking = false

    private var name: String {
        change.displayName ?? change.userId
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: change.wasVerified ? "exclamationmark.shield.fill" : "exclamationmark.shield")
                .foregroundStyle(change.wasVerified ? .red : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.wasVerified
                     ? "\(name)’s verified identity has changed."
                     : "\(name)’s identity has changed.")
                    .bold()
                Text(change.wasVerified
                     ? "Your verification no longer holds. Verify them again, or accept the new identity if you know why it changed."
                     : "Their account may have been reset. If that is not what happened, ask them before sending anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if change.displayName != nil {
                    Text(change.userId)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(change.wasVerified ? "Withdraw Verification" : "Accept") {
                isWorking = true
                Task {
                    await acknowledge(change.userId)
                    isWorking = false
                }
            }
            .disabled(isWorking)
        }
        .accessibilityElement(children: .combine)
    }
}
