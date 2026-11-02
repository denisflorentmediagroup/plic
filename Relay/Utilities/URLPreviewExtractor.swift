// Copyright 2026 Link Dupont
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
import RelayInterface

/// Extracts the first previewable URL from a message body, filtering out
/// Matrix identifiers, `matrix.to` links, hosts on this Mac or its local
/// network, and bare URLs without an explicit scheme.
enum URLPreviewExtractor {

    /// Cache for `firstPreviewURL` results to avoid running `NSDataDetector` on
    /// every SwiftUI body evaluation.
    static let urlCache = ParseCache<String, URL?>(capacity: 256)

    /// Regex matching Matrix identifiers (`@user:server`, `#room:server`,
    /// `!id:server`) whose server portion `NSDataDetector` misidentifies as
    /// a standalone URL.
    private static let matrixIdentifierPattern =
        /[#@!][a-zA-Z0-9._=\-\/]+:[a-zA-Z0-9.\-]+(:[0-9]+)?/

    /// Whether a host is on this Mac or its local network.
    ///
    /// A preview is fetched without anyone clicking, so a message could
    /// otherwise make this Mac send requests to a router's admin page or any
    /// other device on the network. IPv4 literals are parsed with `inet_aton`,
    /// which also reads the forms a plain comparison misses: `127.1` and
    /// `2130706433` are both 127.0.0.1.
    ///
    /// A public name that resolves or redirects to a private address is not
    /// caught here — that would need resolving it first, and vetting every
    /// redirect LinkPresentation follows. It is one more reason previews are
    /// off by default.
    static func isLocalNetworkHost(_ rawHost: String) -> Bool {
        LocalNetworkHost.contains(rawHost)
    }

    /// Returns the first HTTP(S) URL found in the given string, excluding
    /// `matrix.to` links, false positives from Matrix identifiers, and bare
    /// URLs without an explicit scheme (e.g. `example.com`).
    static func firstPreviewURL(in body: String) -> URL? {
        urlCache.value(forKey: body) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return nil
            }
            let matches = detector.matches(in: body, range: NSRange(body.startIndex..., in: body))

            // Collect ranges of Matrix identifiers so we can discard any URL
            // that NSDataDetector extracted from the server portion of one.
            let identifierRanges = body.matches(of: matrixIdentifierPattern).map(\.range)

            for match in matches {
                guard let url = match.url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      url.host?.lowercased() != "matrix.to",
                      !isLocalNetworkHost(url.host ?? ""),
                      let matchRange = Range(match.range, in: body) else { continue }

                // Skip URLs whose detected range overlaps a Matrix identifier.
                if identifierRanges.contains(where: { $0.overlaps(matchRange) }) {
                    continue
                }

                // Only show previews for URLs with an explicit scheme in the
                // original text. NSDataDetector fabricates "http://" for bare
                // hostnames like "example.com" — skip those.
                let originalText = body[matchRange]
                guard originalText.lowercased().hasPrefix("http://")
                   || originalText.lowercased().hasPrefix("https://") else {
                    continue
                }

                return url
            }
            return nil
        }
    }
}
