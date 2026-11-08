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

/// Which links in message text Plic makes clickable, and will open.
///
/// Message text is written by other people, and a clicked link is handed to
/// `NSWorkspace`, which opens anything macOS has a handler for. `NSDataDetector`
/// alone recognises `file:`, `smb:`, `afp:`, `vnc:`, `ssh:`, `shortcuts:` and
/// `applescript:` URLs in plain text, and inline Markdown turns
/// `[the photos](smb://…)` into a link whose destination is hidden behind its
/// text. Launching an app, mounting a hostile share or opening Script Editor
/// with a prepared script would each be one click away.
///
/// So the policy is applied to the finished text, whatever produced the link —
/// HTML, Markdown or detection — and again at click time, for any path that
/// adds a link later.
enum LinkPolicy {
    /// Web, mail and torrent links, and `matrix:` URIs, which Plic resolves
    /// itself and never passes to `NSWorkspace`. Not `ftp`: Finder answers it
    /// by mounting the server, the same hostile-share risk as `smb` or `afp`.
    static let allowedSchemes: Set<String> = ["https", "http", "mailto", "magnet", "matrix"]

    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Whether a link may be handed to another app. `matrix:` is openable in
    /// Plic but has no meaning outside it.
    static func opensOutside(_ url: URL) -> Bool {
        isOpenable(url) && url.scheme?.lowercased() != "matrix"
    }

    /// The link attribute's value as a URL, whichever form it was stored in.
    static func url(from linkValue: Any) -> URL? {
        switch linkValue {
        case let url as URL: url
        case let string as String: URL(string: string)
        default: nil
        }
    }

    /// Strips every link the policy does not allow, leaving its text in place.
    static func removeDisallowedLinks(in text: inout AttributedString) {
        for run in text.runs {
            if let url = run.link, !isOpenable(url) {
                text[run.range].link = nil
            }
        }
    }

    /// Strips every link the policy does not allow, leaving its text in place.
    static func removeDisallowedLinks(in text: NSMutableAttributedString) {
        var disallowed: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value else { return }
            if let url = url(from: value), isOpenable(url) { return }
            disallowed.append(range)
        }
        for range in disallowed {
            text.removeAttribute(.link, range: range)
        }
    }
}
