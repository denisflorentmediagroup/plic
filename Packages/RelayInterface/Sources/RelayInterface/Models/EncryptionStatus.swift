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

import Foundation

/// Where account recovery stands for this account.
public enum RecoveryStatus: Sendable, Equatable {
    /// Not yet known: the client has not finished checking.
    case unknown
    /// A recovery key exists and this session holds the secrets it protects.
    case enabled
    /// No recovery key has been set up.
    case disabled
    /// A recovery key exists, set up on another session, and this session
    /// does not have the secrets yet: entering the key completes it.
    case incomplete
}

/// Summary of the client's encryption, key backup, and recovery state.
public struct EncryptionStatus: Sendable {
    /// Whether server-side key backup is active, allowing message keys to be recovered on new sessions.
    public let backupEnabled: Bool

    /// Where account recovery stands.
    public let recovery: RecoveryStatus

    /// Whether account recovery (via a recovery key or passphrase) has been configured.
    public var recoveryEnabled: Bool { recovery == .enabled }

    /// Creates a new ``EncryptionStatus`` value.
    ///
    /// - Parameters:
    ///   - backupEnabled: `true` when key backup is enabled on the server.
    ///   - recovery: where account recovery stands.
    nonisolated public init(backupEnabled: Bool = false, recovery: RecoveryStatus = .unknown) {
        self.backupEnabled = backupEnabled
        self.recovery = recovery
    }
}
