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
import Security
import Testing

@testable import RelayKit

/// Proves the legacy-keychain purge cannot reach the live session.
///
/// `purgeLegacyItems()` deletes the *same* service/account pair the live
/// session is stored under. Its only safeguard is that it is meant to address a
/// different keychain — the legacy file-based one — than the data-protection
/// keychain `save()` writes to. That separation is not automatic: a query that
/// simply omits `kSecUseDataProtectionKeychain` matches data-protection items
/// too. When it did, the app deleted its own credentials at launch and showed
/// the login screen to a user who had signed in minutes earlier.
///
/// These run inside the test host, so they carry the app's real entitlements —
/// same access group, same keychain. A plain command-line tool cannot reproduce
/// any of it: it gets `errSecMissingEntitlement` before reaching the
/// interesting part.
@Suite(.enabled(if: KeychainProbe.isUsable, "the Keychain is not usable from this test host"))
struct LegacyPurgeScopeTests {

    private static let service = "im.plic"

    @Test("The real purge leaves a data-protection item alone")
    func purgeSparesTheLiveSession() {
        let account = "purge-scope-\(UUID().uuidString)"
        defer { KeychainService.delete(account: account) }

        let payload = Data("live-session".utf8)
        #expect(KeychainService.save(payload, account: account), "setup: the item must be written")
        #expect(KeychainService.load(account: account) == payload, "setup: the item must read back")

        KeychainService.purgeLegacyItems(accounts: [account])

        #expect(
            KeychainService.load(account: account) == payload,
            """
            purgeLegacyItems() destroyed a data-protection item. It runs from \
            AuthenticationService.init on every launch against the live session's \
            own account, so this is the app deleting its own credentials at startup.
            """
        )
    }

    @Test("A delete that omits the data-protection flag is not legacy-only")
    func flaglessDeleteIsNotScopedToLegacy() {
        // The mistake this suite exists to prevent, stated as an executable
        // fact rather than a comment: omitting the flag does NOT confine a
        // delete to the legacy keychain. If a future SDK ever changes that,
        // this test starts failing and the extra safety in purgeLegacyItems
        // can be revisited deliberately instead of by accident.
        let account = "purge-scope-\(UUID().uuidString)"
        defer { KeychainService.delete(account: account) }

        #expect(KeychainService.save(Data("victim".utf8), account: account))

        let flagless: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(flagless as CFDictionary)

        #expect(
            status == errSecSuccess,
            "Expected the flagless delete to reach the data-protection item (got \(status))"
        )
        #expect(KeychainService.load(account: account) == nil)
    }
}
