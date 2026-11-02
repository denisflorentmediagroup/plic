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

import AppKit
import Testing

@testable import Relay

/// Messages built to crash the app rather than to be read.
@MainActor
struct HostileMessageTests {

    @Test("An ordered list cannot overflow its counter",
          arguments: [
            "<ol start=\"-9223372036854775808\"><li>a</li><li>b</li></ol>",
            "<ol start=\"9223372036854775807\"><li>a</li><li>b</li></ol>",
            "<ol start=\"-5\"><li>a</li></ol>",
          ])
    func orderedListStartIsClamped(_ html: String) {
        let rendered = NSAttributedString(matrixHTML: html)
        #expect(rendered != nil)
        #expect(rendered?.string.contains("a") == true)
    }

    @Test("A sane start value is kept")
    func orderedListStartIsKept() {
        let rendered = NSAttributedString(matrixHTML: "<ol start=\"7\"><li>a</li><li>b</li></ol>")
        #expect(rendered?.string.contains("7. a") == true)
        #expect(rendered?.string.contains("8. b") == true)
    }
}
