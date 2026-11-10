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
import MatrixRustSDK
import RelayInterface
import Testing

@testable import RelayKit

/// Pins the wording and linking of system events, and the folding of
/// repeated call events, as the mapper produces them for the timeline.
struct TimelineMessageMapperTests {

    @Test("A membership change names the member and links them",
          arguments: [
            (MembershipChange.joined, " joined the room"),
            (.left, " left the room"),
            (.banned, " was banned"),
            (.kicked, " was removed from the room"),
            (.invited, " was invited"),
            (.kickedAndBanned, " was removed and banned"),
            (.invitationRevoked, "'s invitation was revoked"),
            (.knocked, " requested to join"),
            (.knockDenied, "'s join request was denied"),
            (.notImplemented, " membership changed"),
          ])
    func membership(_ change: MembershipChange, _ suffix: String) {
        let text = TimelineMessageMapper.membershipDescription(
            name: "Jordan Lee", userId: "@jordan:example.org", change: change
        )
        #expect(String(text.characters) == "Jordan Lee" + suffix)
        let link = text.runs.first?.link
        #expect(link?.absoluteString == "https://matrix.to/#/@jordan:example.org")
    }

    @Test("An unknown membership change still produces a sentence")
    func membershipWithoutChange() {
        let text = TimelineMessageMapper.membershipDescription(name: "@x:example.org", change: nil)
        #expect(String(text.characters) == "@x:example.org membership changed")
        #expect(text.runs.first?.link == nil)
    }

    @Test("Profile changes are described from what actually changed")
    func profileChanges() {
        func describe(_ name: String?, _ prev: String?, _ avatar: String?, _ prevAvatar: String?) -> String {
            String(TimelineMessageMapper.profileChangeDescription(
                displayName: name, prevDisplayName: prev,
                avatarUrl: avatar, prevAvatarUrl: prevAvatar,
                senderName: "@s:example.org"
            ).characters)
        }
        #expect(describe("New", "Old", nil, nil) == "Old changed their name to New")
        #expect(describe("New", "Old", "mxc://a", nil) == "Old changed their name to New and updated their avatar")
        #expect(describe("New", nil, nil, nil) == "New set their display name")
        #expect(describe("New", nil, "mxc://a", nil) == "New set their name and updated their avatar")
        #expect(describe(nil, "Old", nil, nil) == "Old removed their display name")
        #expect(describe("Same", "Same", "mxc://b", "mxc://a") == "Same updated their avatar")
        #expect(describe("Same", "Same", nil, "mxc://a") == "Same removed their avatar")
        #expect(describe(nil, nil, "mxc://a", nil) == "@s:example.org updated their avatar")
        #expect(describe("Same", "Same", nil, nil) == "Same updated their profile")
    }

    @Test("Room state changes read as sentences, and a topic is never quoted")
    func stateEvents() {
        #expect(TimelineMessageMapper.stateEventDescription(.roomName(name: "Ops")) == "Room name changed to Ops")
        #expect(TimelineMessageMapper.stateEventDescription(.roomName(name: "")) == "Room name was removed")
        #expect(TimelineMessageMapper.stateEventDescription(.roomTopic(topic: "secret plan")) == "Room topic was changed")
        #expect(TimelineMessageMapper.stateEventDescription(.roomTopic(topic: nil)) == "Room topic was removed")
        #expect(TimelineMessageMapper.stateEventDescription(.roomEncryption) == "Encryption was enabled")
        #expect(TimelineMessageMapper.stateEventDescription(.custom(eventType: "org.example.x")) == "Room settings were updated")
    }

    @Test("Call membership shows as a call; key exchange shows as nothing")
    func callStateEvents() {
        let call = TimelineMessageMapper.describeStateEvent(
            .custom(eventType: "org.matrix.msc3401.call.member"),
            stateKey: "_@a:example.org_DEV", senderDisplayName: "Alex", senderId: "@a:example.org"
        )
        #expect(call.body == "Alex started a call")
        #expect(call.kind == .callEvent)

        let keys = TimelineMessageMapper.describeStateEvent(
            .custom(eventType: "io.element.call.encryption_keys"),
            stateKey: "", senderDisplayName: nil, senderId: "@a:example.org"
        )
        #expect(keys.body == nil)
    }

    @Test("Consecutive call events from one sender fold into the first")
    func callEventsFold() {
        func message(_ id: String, _ sender: String, _ kind: TimelineMessage.Kind) -> TimelineMessage {
            TimelineMessage(id: id, senderID: sender, body: "", timestamp: .now, isOutgoing: false, kind: kind)
        }
        let folded = TimelineMessageMapper.deduplicateCallEvents([
            message("1", "@a:example.org", .callEvent),
            message("2", "@a:example.org", .callEvent),
            message("3", "@b:example.org", .callEvent),
            message("4", "@b:example.org", .text),
            message("5", "@b:example.org", .callEvent),
        ])
        #expect(folded.map(\.id) == ["1", "3", "4", "5"])
    }
}
