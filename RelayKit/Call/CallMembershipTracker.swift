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

/// The devices currently in a call, as announced by their
/// `org.matrix.msc3401.call.member` state events.
///
/// Call media keys are addressed to exactly these devices. Addressing them to
/// a user's `*` instead makes the SDK encrypt for every device of that user it
/// knows — its widget path uses `CollectStrategy::AllDevices`, bypassing the
/// identity-based strategy Plic sets for room keys — so a device added with a
/// stolen password would receive the key without ever appearing in the call.
///
/// Fed by the widget driver, which pushes the room's current memberships when
/// the widget starts and every change after that. Nothing here reads the
/// network or holds a token that could expire mid-call.
nonisolated struct CallMembershipTracker {
    struct Member: Equatable {
        let userId: String
        let deviceId: String
        /// When the membership lapses if not renewed; `nil` when the event
        /// advertises no expiry.
        let expiresAt: Date?
    }

    /// Current members, keyed by the state key of the event that announced
    /// them. One state key can carry several devices in the legacy format.
    private(set) var membersByStateKey: [String: [Member]] = [:]

    /// Applies one state event. Returns whether the membership changed.
    ///
    /// Events of other types are ignored. An empty content is a departure.
    @discardableResult
    mutating func apply(event: [String: Any]) -> Bool {
        guard (event["type"] as? String) == CallEncryptionService.callMemberEventType,
              let stateKey = event["state_key"] as? String,
              let sender = event["sender"] as? String,
              // A member may only announce, or withdraw, their own devices:
              // the state key is the sender's user ID or starts with it.
              stateKey == sender || stateKey.hasPrefix("_\(sender)_")
        else { return false }

        let content = event["content"] as? [String: Any] ?? [:]
        let originTs = Self.milliseconds(event["origin_server_ts"])
        let members = Self.members(sender: sender, content: content, originTs: originTs)

        let previous = membersByStateKey[stateKey] ?? []
        if members.isEmpty {
            membersByStateKey[stateKey] = nil
        } else {
            membersByStateKey[stateKey] = members
        }
        return previous != members
    }

    /// Applies a batch, as delivered by the widget driver's `update_state`.
    @discardableResult
    mutating func apply(events: [[String: Any]]) -> Bool {
        var changed = false
        for event in events where apply(event: event) {
            changed = true
        }
        return changed
    }

    /// The devices to send this device's key to: every live member other than
    /// this device itself — including the user's own other devices in the
    /// call, which need the key as much as anyone.
    func targets(ownUserId: String, ownDeviceId: String, now: Date = .now) -> [String: [String]] {
        var byUser: [String: Set<String>] = [:]
        for member in membersByStateKey.values.joined() {
            if member.userId == ownUserId, member.deviceId == ownDeviceId { continue }
            if let expiresAt = member.expiresAt, expiresAt <= now { continue }
            byUser[member.userId, default: []].insert(member.deviceId)
        }
        return byUser.mapValues { $0.sorted() }
    }

    // MARK: - Parsing

    /// Both formats in circulation: one device per event (`device_id` at the
    /// top level, what Element X and Plic publish) and the legacy per-user
    /// event listing a `memberships` array.
    ///
    /// The user is always the event's sender, never a field of the content:
    /// state events can only be sent as oneself, so a member can only direct
    /// keys to their own devices.
    private static func members(sender: String, content: [String: Any], originTs: Double?) -> [Member] {
        if let deviceId = content["device_id"] as? String, !deviceId.isEmpty {
            return [member(sender: sender, deviceId: deviceId, fields: content, originTs: originTs)]
        }
        if let memberships = content["memberships"] as? [[String: Any]] {
            return memberships.compactMap { entry in
                guard let deviceId = entry["device_id"] as? String, !deviceId.isEmpty else { return nil }
                return member(sender: sender, deviceId: deviceId, fields: entry, originTs: originTs)
            }
        }
        return []
    }

    private static func member(
        sender: String, deviceId: String, fields: [String: Any], originTs: Double?
    ) -> Member {
        var expiresAt: Date?
        if let lifetime = milliseconds(fields["expires"]),
           let start = milliseconds(fields["created_ts"]) ?? originTs {
            expiresAt = Date(timeIntervalSince1970: (start + lifetime) / 1000)
        }
        return Member(userId: sender, deviceId: deviceId, expiresAt: expiresAt)
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let int as Int: Double(int)
        case let double as Double: double
        default: nil
        }
    }
}
