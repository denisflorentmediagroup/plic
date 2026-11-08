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

@testable import RelayInterface

/// Pins which hosts count as this Mac or its network, for link previews and
/// call servers alike.
struct LocalNetworkHostTests {

    @Test("Local hosts, however spelled",
          arguments: [
            "localhost", "localhost.", "LOCALHOST", "nas", "printer.local", "router.lan",
            "127.0.0.1", "127.1", "2130706433", "10.1.2.3", "172.31.255.255", "192.168.0.1",
            "169.254.1.1", "100.64.0.1", "0.0.0.0", "198.18.0.1", "224.0.0.251", "255.255.255.255",
            "::1", "[::1]", "fe80::1", "fd00::1", "::ffff:192.168.1.1", "64:ff9b::c0a8:101", "ff02::1",
          ])
    func local(_ host: String) {
        #expect(LocalNetworkHost.contains(host))
    }

    @Test("Public hosts",
          arguments: [
            "matrix.org", "example.org.", "8.8.8.8", "1.1.1.1", "172.32.0.1", "192.169.0.1",
            "2606:4700::1111", "64:ff9b::808:808",
          ])
    func notLocal(_ host: String) {
        #expect(!LocalNetworkHost.contains(host))
    }
}
