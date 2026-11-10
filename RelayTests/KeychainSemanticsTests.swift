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

/// Covers the update-or-add semantics of the session store.
///
/// `save` used to delete before adding, so a transient failure during an OIDC
/// token refresh destroyed the only copy of the session and logged the user out
/// at the next launch. The rewrite updates in place; these tests pin that down.
///
/// Everything runs against a scratch account created and deleted per test. The
/// real session account is never touched: the test host shares the developer's
/// keychain, and writing to `matrix-session-debug` would destroy their live
/// login — which is also why `KeychainService` grew account-parameterised
/// variants in the first place.
@Suite(.enabled(if: KeychainProbe.isUsable, "the Keychain is not usable from this test host"))
struct KeychainSemanticsTests {

    @Test("Add path: a first save lands and reads back")
    func firstSaveReadsBack() {
        let account = "test-scratch-\(UUID().uuidString)"
        defer { KeychainService.delete(account: account) }

        let payload = Data("session-A".utf8)
        #expect(KeychainService.save(payload, account: account))
        #expect(KeychainService.load(account: account) == payload)
    }

    @Test("Update path: a second save replaces without duplicating")
    func secondSaveReplaces() {
        let account = "test-scratch-\(UUID().uuidString)"
        defer { KeychainService.delete(account: account) }

        #expect(KeychainService.save(Data("session-A".utf8), account: account))
        #expect(KeychainService.save(Data("session-B".utf8), account: account))
        // The old delete-then-add would also pass this assertion, so it is the
        // save() return values above that carry the regression check: with
        // update-or-add, the second save exercises SecItemUpdate and must
        // still report success.
        #expect(KeychainService.load(account: account) == Data("session-B".utf8))
    }

    @Test("Delete removes the item")
    func deleteRemoves() {
        let account = "test-scratch-\(UUID().uuidString)"
        KeychainService.save(Data("ephemeral".utf8), account: account)
        KeychainService.delete(account: account)
        #expect(KeychainService.load(account: account) == nil)
    }
}
