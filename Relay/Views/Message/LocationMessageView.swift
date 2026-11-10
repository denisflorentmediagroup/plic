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
import RelayInterface
import SwiftUI

/// A shared place: its name or coordinates, and a button that opens it in
/// Maps. No map is drawn here, because drawing one means asking a tile
/// server for exactly these coordinates, which nobody asked Plic to do.
struct LocationMessageView: View {
    let message: TimelineMessage
    let location: TimelineMessage.Location

    private var style: BubbleStyle {
        .special(kind: .location)
    }

    private var coordinateText: String? {
        guard let (latitude, longitude) = location.coordinates else { return nil }
        let lat = latitude.formatted(.number.precision(.fractionLength(5)))
        let lon = longitude.formatted(.number.precision(.fractionLength(5)))
        return "\(lat), \(lon)"
    }

    private var mapsURL: URL? {
        guard let (latitude, longitude) = location.coordinates else { return nil }
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        var items = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
        if let description = location.description, !description.isEmpty {
            items.append(URLQueryItem(name: "q", value: description))
        }
        components.queryItems = items
        return components.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let description = location.description, !description.isEmpty {
                        Text(description)
                            .bold()
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Location")
                            .bold()
                    }
                    if let coordinateText {
                        Text(coordinateText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
            if let mapsURL {
                Button("Open in Maps", systemImage: "map") {
                    NSWorkspace.shared.open(mapsURL)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, BubbleStyle.horizontalPadding)
        .padding(.vertical, BubbleStyle.verticalPadding)
        .background(style.backgroundColor)
        .clipShape(BubbleStyle.shape)
        .accessibilityElement(children: .combine)
    }
}
