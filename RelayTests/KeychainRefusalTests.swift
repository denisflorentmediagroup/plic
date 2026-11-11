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

/// Pins the rule that Plic opens nothing it cannot encrypt.
///
/// Before this, a Keychain that refused the store key made the SDK open its
/// stores in plaintext — "degraded, but still usable". The product promises
/// that everything cached is encrypted; this is where that promise is kept.
@MainActor
struct KeychainRefusalTests {

    // The refusal is the first thing makeBuilder() does, so this touches no
    // directory. A test that supplied a stub key would go further and reach the
    // real search index, whose stamp would not match — and discard it.
    @Test("No key, no client: the builder refuses instead of opening plaintext")
    func builderRefusesWithoutKey() {
        let auth = AuthenticationService(networkMonitor: NetworkMonitor(), storeKey: { nil })
        #expect(throws: KeychainUnavailableError.self) {
            try auth.makeBuilder()
        }
    }

    @Test("A Keychain item that was never written reads as absent, not as a failure",
          .enabled(if: KeychainProbe.isUsable, "the Keychain is not usable from this test host"))
    func missingItemIsNotFound() {
        // The distinction the recovery screens depend on: "absent" may lead to
        // clearing data, so it must only ever mean absent.
        let lookup = KeychainService.lookUp(account: "plic.test.never-written.\(UUID().uuidString)")
        guard case .notFound = lookup else {
            Issue.record("expected .notFound, got \(lookup)")
            return
        }
    }
}
