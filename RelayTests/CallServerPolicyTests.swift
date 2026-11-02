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

/// Pins which call server addresses Plic agrees to contact. Any room member
/// can advertise one, and it receives the user's OpenID token and media.
struct CallServerPolicyTests {

    @Test("A public https call server is accepted")
    func acceptsPublicHTTPS() {
        #expect(LiveKitCredentialService.isAcceptableServiceURL("https://livekit.example.org"))
        #expect(LiveKitCredentialService.isAcceptableServiceURL("https://livekit.example.org:8443/livekit/jwt"))
    }

    @Test("Plain http, other schemes and credentials in the address are refused",
          arguments: [
            "http://livekit.example.org",
            "wss://livekit.example.org",
            "ftp://livekit.example.org",
            "https://user:secret@livekit.example.org",
            "livekit.example.org",
            "",
          ])
    func refusesInsecureServiceURL(_ raw: String) {
        #expect(!LiveKitCredentialService.isAcceptableServiceURL(raw))
    }

    @Test("Addresses on this Mac or its network are refused, however spelled",
          arguments: [
            "https://localhost",
            "https://127.0.0.1",
            "https://127.1",
            "https://2130706433",
            "https://192.168.1.1:7880",
            "https://10.0.0.5",
            "https://[::1]",
            "https://[fe80::1]",
            "https://router.local",
            "https://nas",
          ])
    func refusesLocalServiceURL(_ raw: String) {
        #expect(!LiveKitCredentialService.isAcceptableServiceURL(raw))
    }

    @Test("The media server must be wss or https, on a public host")
    func mediaURL() {
        #expect(LiveKitCredentialService.isAcceptableMediaURL("wss://sfu.example.org"))
        #expect(LiveKitCredentialService.isAcceptableMediaURL("https://sfu.example.org"))
        #expect(!LiveKitCredentialService.isAcceptableMediaURL("ws://sfu.example.org"))
        #expect(!LiveKitCredentialService.isAcceptableMediaURL("wss://192.168.0.2"))
    }
}
