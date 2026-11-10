// Copyright 2026 Denis Florent
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

/// Covers the key that encrypts the SDK's local SQLite stores.
///
/// These stores hold the Olm account, Megolm sessions and device keys, so the
/// key's properties are load-bearing: the wrong length makes SQLCipher reject
/// it, and a key that changes between launches makes every past message
/// permanently unreadable.
///
/// The tests run against the real Keychain under the `-debug` account that
/// ``KeychainService`` selects in DEBUG builds, so they never touch the key a
/// release build would use.
@Suite(.enabled(if: KeychainProbe.isUsable, "the Keychain is not usable from this test host"))
struct StoreKeyTests {

    @Test("The store key is 256 bits, as SQLCipher expects")
    func storeKeyIsTwoHundredFiftySixBits() throws {
        let key = try #require(
            KeychainService.loadOrCreateStoreKey(),
            "The Keychain refused both the read and the write"
        )
        #expect(key.count == 32)
    }

    @Test("The same key comes back on every call")
    func storeKeyIsStable() throws {
        let first = try #require(KeychainService.loadOrCreateStoreKey())
        let second = try #require(KeychainService.loadOrCreateStoreKey())
        // A key that regenerates would silently orphan the existing store and
        // take every decryptable message with it.
        #expect(first == second)
    }

    @Test("The key is not all zeroes")
    func storeKeyIsNotDegenerate() throws {
        let key = try #require(KeychainService.loadOrCreateStoreKey())
        #expect(key.contains { $0 != 0 })
    }

    @Test("The key never leaves this Mac")
    func storeKeyIsThisDeviceOnly() throws {
        _ = KeychainService.loadOrCreateStoreKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: "im.plic",
            kSecAttrAccount as String: "store-key-debug",
            kSecAttrAccessGroup as String: AppGroup.identifier,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try #require(status == errSecSuccess, "Stored key not found (OSStatus \(status))")

        let attributes = try #require(result as? [String: Any])
        let accessible = attributes[kSecAttrAccessible as String] as? String
        // Anything without the ThisDeviceOnly suffix rides along in backups and
        // can be restored onto hardware the user no longer controls.
        #expect(accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }
}
