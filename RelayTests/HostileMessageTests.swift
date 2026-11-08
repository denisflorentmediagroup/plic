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

    @Test("A flood of unclosed tags or comments parses in linear time",
          arguments: [
            String(repeating: "<", count: 65_536),
            String(repeating: "<!--", count: 16_384),
            String(repeating: "<a<b<c ", count: 10_000),
          ])
    func tokenizerFloodIsLinear(_ html: String) {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = NSAttributedString(matrixHTML: html)
        }
        #expect(elapsed < .seconds(2))
    }

    @Test("Text after an unclosed tag is still shown")
    func unclosedTagKeepsText() {
        let rendered = NSAttributedString(matrixHTML: "before <b>bold</b> 1 < 2 &amp; done")
        #expect(rendered?.string.contains("1 < 2 & done") == true)
    }

    @Test("A comment ends only at its own -->")
    func commentIsSkipped() {
        let rendered = NSAttributedString(matrixHTML: "a<!-- hidden -- > still hidden -->b")
        #expect(rendered?.string == "ab")
    }

    @Test("Only so many identifiers become links")
    func identifierLinksAreCapped() {
        let plain = (0..<200).map { "@user\($0):example.org" }.joined(separator: " ")
        var text = AttributedString(plain)
        MatrixIdentifierLinker.linkify(&text)
        let links = text.runs.filter { $0.link != nil }.count
        #expect(links == MatrixIdentifierLinker.maximumLinks)
    }

    @Test("A mention's display name cannot break out of its link",
          arguments: [
            ("x](https://evil.example) [y", "x\\]\\(https\\:\\/\\/evil\\.example\\) \\[y"),
            ("<img src=x onerror=1>", "\\<img src\\=x onerror\\=1\\>"),
            ("Jane\nDoe", "Jane Doe"),
            ("Jane Doe", "Jane Doe"),
            ("Zoë", "Zoë"),
          ])
    func mentionNameIsEscaped(_ name: String, _ expected: String) {
        #expect(ComposeViewModel.markdownEscaped(name) == expected)
    }

    @Test("ftp links are not opened; matrix links never leave Plic")
    func linkPolicy() throws {
        #expect(!LinkPolicy.isOpenable(try #require(URL(string: "ftp://files.example.org/x"))))
        #expect(LinkPolicy.isOpenable(try #require(URL(string: "matrix:r/room:example.org"))))
        #expect(!LinkPolicy.opensOutside(try #require(URL(string: "matrix:r/room:example.org"))))
        #expect(LinkPolicy.opensOutside(try #require(URL(string: "https://example.org"))))
        #expect(!LinkPolicy.opensOutside(try #require(URL(string: "file:///etc/passwd"))))
    }
}
