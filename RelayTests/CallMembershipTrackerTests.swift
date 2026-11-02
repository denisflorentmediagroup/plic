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

/// Pins who receives a call's media key.
///
/// The SDK's widget path encrypts to-device messages with
/// `CollectStrategy::AllDevices`: asked for a user's `*`, it serves every
/// device it knows of that user, verified or not. These tests hold Plic to
/// addressing only the devices that announced themselves in the call.
struct CallMembershipTrackerTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var nowMs: Int { Int(now.timeIntervalSince1970 * 1000) }

    /// A membership in the per-device format Plic and Element X publish.
    private func member(_ user: String, _ device: String, createdMs: Int? = nil, expiresMs: Int = 14_400_000) -> [String: Any] {
        [
            "type": CallEncryptionService.callMemberEventType,
            "state_key": "_\(user)_\(device)_m.call",
            "sender": user,
            "origin_server_ts": createdMs ?? nowMs,
            "content": [
                "application": "m.call", "call_id": "", "device_id": device,
                "created_ts": createdMs ?? nowMs, "expires": expiresMs,
                "membershipID": UUID().uuidString, "scope": "m.room",
            ] as [String: Any],
        ]
    }

    private func departure(_ user: String, _ device: String) -> [String: Any] {
        ["type": CallEncryptionService.callMemberEventType, "state_key": "_\(user)_\(device)_m.call",
         "sender": user, "content": [String: Any]()]
    }

    @Test("Keys go to the devices in the call, never to a user's every device")
    func targetsAreExplicitDevices() {
        var tracker = CallMembershipTracker()
        tracker.apply(events: [member("@alice:a.org", "ALICEPHONE"), member("@bob:b.org", "BOBMAC")])

        let targets = tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now)

        #expect(targets == ["@alice:a.org": ["ALICEPHONE"], "@bob:b.org": ["BOBMAC"]])
        #expect(!targets.values.joined().contains("*"))
    }

    @Test("This device is excluded, the user's other devices in the call are not")
    func ownDevice() {
        var tracker = CallMembershipTracker()
        tracker.apply(events: [member("@me:m.org", "PLIC"), member("@me:m.org", "MYPHONE")])

        // The phone joined the same call and must be able to decrypt this Mac.
        #expect(tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now) == ["@me:m.org": ["MYPHONE"]])
    }

    @Test("A departure removes the device")
    func departureRemoves() {
        var tracker = CallMembershipTracker()
        tracker.apply(event: member("@alice:a.org", "ALICEPHONE"))
        let changed = tracker.apply(event: departure("@alice:a.org", "ALICEPHONE"))

        #expect(changed)
        #expect(tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now).isEmpty)
    }

    @Test("A lapsed membership no longer receives keys")
    func expiredIsExcluded() {
        var tracker = CallMembershipTracker()
        // Created five hours ago with a four-hour lifetime: a client that
        // crashed without leaving.
        tracker.apply(event: member("@alice:a.org", "STALE", createdMs: nowMs - 5 * 3_600_000))

        #expect(tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now).isEmpty)
    }

    @Test("An event under someone else's state key counts for nobody")
    func senderIsAuthoritative() {
        var tracker = CallMembershipTracker()
        // Mallory announces a device under Alice's state key. The event is
        // dropped: it can neither steer a key to Alice's device nor earn
        // Mallory one, since nothing says Mallory holds a device in the call.
        var forged = member("@mallory:x.org", "ALICEPHONE")
        forged["state_key"] = "_@alice:a.org_ALICEPHONE_m.call"
        let applied = tracker.apply(event: forged)

        #expect(!applied)
        #expect(tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now).isEmpty)
    }

    @Test("The legacy per-user format is understood")
    func legacyFormat() {
        var tracker = CallMembershipTracker()
        tracker.apply(event: [
            "type": CallEncryptionService.callMemberEventType, "state_key": "@carol:c.org",
            "sender": "@carol:c.org", "origin_server_ts": nowMs,
            "content": ["memberships": [
                ["device_id": "CAROL1", "expires": 3_600_000, "created_ts": nowMs],
                ["device_id": "CAROL2", "expires": 3_600_000, "created_ts": nowMs],
            ]] as [String: Any],
        ])

        #expect(tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now) == ["@carol:c.org": ["CAROL1", "CAROL2"]])
    }

    @Test("Other event types and replays change nothing")
    func noiseIsIgnored() {
        var tracker = CallMembershipTracker()
        let event = member("@alice:a.org", "ALICEPHONE")
        let first = tracker.apply(event: event)
        let replay = tracker.apply(event: event)
        let unrelated = tracker.apply(event: ["type": "m.room.topic", "state_key": "", "sender": "@alice:a.org"])
        #expect(first)
        #expect(replay == false, "an identical event is not a change")
        #expect(unrelated == false)
    }
    @Test("A member can only announce or withdraw their own devices")
    func stateKeyMustBelongToSender() {
        var tracker = CallMembershipTracker()
        tracker.apply(events: [member("@alice:a.org", "ALICEPHONE")])

        // Mallory writes under Alice's state key: a departure, then a device.
        var eviction = departure("@alice:a.org", "ALICEPHONE")
        eviction["sender"] = "@mallory:m.org"
        var takeover = member("@alice:a.org", "ALICEPHONE")
        takeover["sender"] = "@mallory:m.org"

        let evicted = tracker.apply(event: eviction)
        let takenOver = tracker.apply(event: takeover)
        #expect(!evicted)
        #expect(!takenOver)
        let targets = tracker.targets(ownUserId: "@me:m.org", ownDeviceId: "PLIC", now: now)
        #expect(targets == ["@alice:a.org": ["ALICEPHONE"]])
    }
}
