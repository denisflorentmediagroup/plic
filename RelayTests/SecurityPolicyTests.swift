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

import Testing

@testable import RelayKit

/// Asserts that the security posture actually reaches the SDK builder.
///
/// Every guarantee below is a single call inside
/// `AuthenticationService.makeBuilder()`. Nothing in the app breaks visibly if
/// one of them is deleted — the app compiles, launches and chats, it just stops
/// being the product it claims to be. These tests are the only thing standing
/// between an accidental refactor and a silent loss of the posture:
/// `ClientBuilderProxy` records what it was configured with, in non-sensitive
/// form, precisely so this suite can read it back.
// The builder reads the store key from the Keychain; where a test host
// cannot use one, there is no builder to inspect.
@Suite(.enabled(if: KeychainProbe.isUsable, "the Keychain is not usable from this test host"))
@MainActor
struct SecurityPolicyTests {

    private func makeConfiguredBuilder() throws -> ClientBuilderProxy {
        try AuthenticationService(networkMonitor: NetworkMonitor()).makeBuilder()
    }

    @Test("Room keys go only to identity-signed devices (MSC4153)")
    func recipientStrategyIsIdentityBased() throws {
        let builder = try makeConfiguredBuilder()
        // The strategy Element runs in its "exclude insecure devices" mode.
        // Any other value — or none, which falls back to the SDK default that
        // still shares with unsigned devices — is a regression of the app's
        // central promise.
        #expect(builder.configuredRecipientStrategy == .identityBasedStrategy)
    }

    @Test("The local stores open with encryption")
    func storeIsEncrypted() throws {
        let builder = try makeConfiguredBuilder()
        // False here means the Keychain key path broke and the Olm account,
        // Megolm sessions and device keys would land on disk in plaintext.
        #expect(builder.configuredStoreEncryption)
    }

    @Test("The search index is enabled, and never without the store key")
    func searchIndexRequiresKey() throws {
        let builder = try makeConfiguredBuilder()
        // The index holds decrypted message text. Enabled without the store
        // key would mean either a plaintext index or one written with a
        // throwaway password — both regressions this suite exists to catch.
        #expect(builder.configuredSearchIndex)
        #expect(
            !builder.configuredSearchIndex || builder.configuredStoreEncryption,
            "An index without store encryption means the key path broke mid-way"
        )
    }

    @Test("The app identifies itself as Plic to homeservers")
    func userAgentIsPlic() throws {
        let builder = try makeConfiguredBuilder()
        #expect(builder.configuredUserAgent == "Plic")
    }
}
