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
import Testing

@testable import RelayKit

/// Whether this machine lets the test host use the Keychain.
///
/// A continuous-integration runner may not: the host is unsigned there, and
/// a locked or absent login keychain refuses every write. The tests that
/// exercise the Keychain itself are skipped in that case rather than failing
/// for a reason that has nothing to do with Plic.
nonisolated enum KeychainProbe {
    static let isUsable: Bool = {
        let account = "plic.test.probe.\(UUID().uuidString)"
        defer { KeychainService.delete(account: account) }
        return KeychainService.save(Data([1]), account: account)
            && KeychainService.load(account: account) == Data([1])
    }()
}
