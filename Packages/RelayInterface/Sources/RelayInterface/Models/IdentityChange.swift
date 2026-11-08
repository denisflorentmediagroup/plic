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

import Foundation

/// A room member whose encryption identity is no longer the one this
/// account knew.
///
/// An identity changes when the account is reset — or when a server
/// substitutes its own keys to read the room. Until the user has seen it,
/// the change stays on screen.
public struct IdentityChange: Identifiable, Hashable, Sendable {
    /// The member's Matrix user ID.
    public let userId: String
    /// The member's display name in this room, when known.
    public let displayName: String?
    /// Whether the user had verified the previous identity by hand. Such a
    /// change is the more serious: the verification is lost with it.
    public let wasVerified: Bool

    public var id: String { userId }

    public init(userId: String, displayName: String?, wasVerified: Bool) {
        self.userId = userId
        self.displayName = displayName
        self.wasVerified = wasVerified
    }
}
