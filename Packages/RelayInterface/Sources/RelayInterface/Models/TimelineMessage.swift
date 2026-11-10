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

/// A single message (or event) within a room's timeline.
///
/// ``TimelineMessage`` is the primary model used by the UI to render chat bubbles. It
/// supports text, emote, media, and special event types, and carries associated metadata
/// such as reactions, reply context, and highlight state.
public struct TimelineMessage: Identifiable, Sendable, Equatable {
    /// The delivery state of an outgoing message.
    public enum SendState: Sendable, Equatable {
        /// The message has not been sent to the server yet (local echo).
        case notSentYet
        /// The message failed to send. The associated value is a human-readable reason.
        case sendingFailed(String)
        /// The message was successfully delivered to the server.
        case sent
    }

    /// The content type of a timeline message.
    public enum Kind: Sendable, Equatable {
        /// A regular text message (optionally with Markdown formatting).
        case text
        /// An emote action (displayed as "* username does something").
        case emote
        /// A notice or system message (non-interactive informational text).
        case notice
        /// An image attachment.
        case image
        /// A video attachment.
        case video
        /// An audio attachment.
        case audio
        /// A generic file attachment.
        case file
        /// A shared geographic location.
        case location
        /// A sticker image.
        case sticker
        /// A poll event.
        case poll
        /// A message that has been deleted (redacted) by a user or moderator.
        case redacted
        /// A message that could not be decrypted (missing encryption keys).
        case encrypted
        /// Any other unsupported or unrecognized event type.
        case other
        /// A live shared geographic location.
        case liveLocation
        /// A room membership change (user joined, left, was kicked, banned, invited, etc.).
        case membership
        /// A profile change (display name or avatar update).
        case profileChange
        /// A room state change (room name, topic, avatar, encryption, join rules, etc.).
        case stateEvent
        /// A call-related event (user started, joined, or left a call).
        case callEvent
    }

    /// A group of emoji reactions attached to a message, aggregated by reaction key.
    public struct ReactionGroup: Sendable, Equatable, Identifiable {
        /// The stable identifier for this reaction group, derived from ``key``.
        public var id: String { key }

        /// The emoji or text key for this reaction (e.g. `"👍"` or `"❤️"`).
        public let key: String

        /// The total number of users who sent this reaction.
        public let count: Int

        /// The Matrix user IDs of all senders of this reaction.
        public let senderIDs: [String]

        /// Whether the current user has sent this particular reaction.
        public let highlightedByCurrentUser: Bool

        /// Creates a new ``ReactionGroup`` value.
        ///
        /// - Parameters:
        ///   - key: The emoji or text key for the reaction.
        ///   - count: The number of senders.
        ///   - senderIDs: The user IDs of all senders.
        ///   - highlightedByCurrentUser: Whether the current user reacted with this key.
        nonisolated public init(key: String, count: Int, senderIDs: [String], highlightedByCurrentUser: Bool) {
            self.key = key
            self.count = count
            self.senderIDs = senderIDs
            self.highlightedByCurrentUser = highlightedByCurrentUser
        }
    }

    /// Context about the parent message when this message is a reply.
    public struct ReplyDetail: Sendable, Equatable {
        /// The event ID of the message being replied to.
        public let eventID: String

        /// The Matrix user ID of the sender of the original message.
        public let senderID: String

        /// The display name of the original sender, if known.
        public var senderDisplayName: String?

        /// The text body of the original message.
        public let body: String

        /// The HTML-formatted body of the original message, if available.
        public let formattedBody: String?

        /// The `mxc://` URL of the image, when the replied-to message is an
        /// image. Used by ``ReplyPreviewBubble`` to show a small thumbnail
        /// instead of the filename text.
        public let imageURL: String?

        /// Creates a new ``ReplyDetail`` value.
        ///
        /// - Parameters:
        ///   - eventID: The event ID of the original message.
        ///   - senderID: The user ID of the original sender.
        ///   - senderDisplayName: The display name of the original sender.
        ///   - body: The body text of the original message.
        ///   - formattedBody: The HTML-formatted body, if available.
        ///   - imageURL: The `mxc://` URL when the original is an image message.
        nonisolated public init(
            eventID: String,
            senderID: String,
            senderDisplayName: String? = nil,
            body: String,
            formattedBody: String? = nil,
            imageURL: String? = nil
        ) {
            self.eventID = eventID
            self.senderID = senderID
            self.senderDisplayName = senderDisplayName
            self.body = body
            self.formattedBody = formattedBody
            self.imageURL = imageURL
        }

        /// The best available display name for the original sender, falling back to the user ID.
        nonisolated public var displayName: String {
            senderDisplayName ?? senderID
        }
    }

    /// Metadata about a media attachment (image, video, audio, or file) associated with a message.
    public struct MediaInfo: Sendable, Equatable {
        /// The `mxc://` URL pointing to the media content on the homeserver.
        public var mxcURL: String

        /// A JSON-serialized representation of the media source, preserving encryption metadata.
        ///
        /// For encrypted media, this contains the encryption keys, IV, and hashes needed to
        /// decrypt the downloaded content. For unencrypted media, this may be `nil` (the
        /// ``mxcURL`` alone is sufficient).
        public var mediaSourceJSON: String?

        /// The original filename of the uploaded media.
        public var filename: String

        /// The MIME type of the media (e.g. `"image/jpeg"`), if known.
        public var mimetype: String?

        /// The width of the media in pixels, if applicable.
        public var width: UInt64?

        /// The height of the media in pixels, if applicable.
        public var height: UInt64?

        /// The file size in bytes, if known.
        public var size: UInt64?

        /// An optional text caption attached to the media.
        public var caption: String?

        /// The duration of the media in seconds, if applicable (audio/video).
        public var duration: TimeInterval?

        /// Whether the sender recorded this as a voice message rather than
        /// attaching an audio file, per [MSC3245].
        ///
        /// The distinction drives presentation: a voice message has no filename
        /// worth showing — senders generate names like
        /// `voice-message-recording.ogg` — while an attached track does.
        ///
        /// [MSC3245]: https://github.com/matrix-org/matrix-spec-proposals/pull/3245
        public var isVoiceMessage: Bool

        /// Amplitude samples describing the recording's shape, if the sender
        /// supplied them.
        ///
        /// Matrix carries these on a 0–1024 scale. Senders are not obliged to
        /// include them, so a client that wants a waveform for every voice
        /// message has to compute its own when this is `nil`.
        public var waveform: [UInt16]?

        /// Creates a new ``MediaInfo`` value.
        ///
        /// - Parameters:
        ///   - mxcURL: The `mxc://` URL for the media content.
        ///   - mediaSourceJSON: The JSON-serialized media source with encryption metadata.
        ///   - filename: The original filename.
        ///   - mimetype: The MIME type of the media.
        ///   - width: The width in pixels.
        ///   - height: The height in pixels.
        ///   - size: The file size in bytes.
        ///   - caption: An optional text caption.
        ///   - duration: The duration in seconds (audio/video).
        ///   - isVoiceMessage: Whether the sender recorded this as a voice message.
        ///   - waveform: Sender-supplied amplitude samples on a 0–1024 scale.
        nonisolated public init(
            mxcURL: String,
            mediaSourceJSON: String? = nil,
            filename: String,
            mimetype: String? = nil,
            width: UInt64? = nil,
            height: UInt64? = nil,
            size: UInt64? = nil,
            caption: String? = nil,
            duration: TimeInterval? = nil,
            isVoiceMessage: Bool = false,
            waveform: [UInt16]? = nil
        ) {
            self.mxcURL = mxcURL
            self.mediaSourceJSON = mediaSourceJSON
            self.filename = filename
            self.mimetype = mimetype
            self.width = width
            self.height = height
            self.size = size
            self.caption = caption
            self.duration = duration
            self.isVoiceMessage = isVoiceMessage
            self.waveform = waveform
        }
    }

    /// A stable, opaque identifier for this message that remains constant across the
    /// local echo → server confirmation transition. Derived from the SDK's `uniqueId()`.
    ///
    /// Use this value (via ``Identifiable/id``) for table diffing, SwiftUI identity,
    /// and any purpose that requires a stable identity. For SDK operations that require
    /// an event or transaction ID, use ``eventID`` instead.
    public let id: String

    /// The Matrix event ID (prefixed with `$`) or transaction ID for this message.
    ///
    /// Use this value when calling SDK methods that require an ``EventOrTransactionId``
    /// (edit, redact, react, pin, send read receipt). For identity and diffing, use
    /// ``id`` instead.
    public let eventID: String

    /// The Matrix user ID of the sender (e.g. `"@alice:matrix.org"`).
    public let senderID: String

    /// The display name of the sender, if available.
    public var senderDisplayName: String?

    /// The `mxc://` URL of the sender's avatar, if available.
    public var senderAvatarURL: String?

    /// The text body of the message (may contain Markdown formatting).
    public var body: String

    /// A rich-text version of the message body with embedded link attributes.
    ///
    /// For system events (membership changes, profile updates), user names carry
    /// `matrix.to` link attributes so they render as clickable mentions. Regular
    /// messages leave this `nil` and use ``formattedBody`` instead.
    public var attributedBody: AttributedString?

    /// The HTML-formatted body of the message, when the sender used `org.matrix.custom.html` format.
    ///
    /// When non-nil, the UI should prefer rendering this over ``body``, falling back to ``body``
    /// only when HTML parsing fails or the format is unsupported.
    public var formattedBody: String?

    /// The time at which this message was sent.
    public var timestamp: Date

    /// Whether this message was sent by the current user.
    public var isOutgoing: Bool

    /// The content type of this message.
    public var kind: Kind

    /// Media attachment metadata, present when ``kind`` is `.image`, `.video`, `.audio`, or `.file`.
    public var mediaInfo: MediaInfo?

    /// The aggregated emoji reactions on this message.
    public var reactions: [ReactionGroup]

    /// Whether this message mentions the current user (used for visual highlighting).
    public var isHighlighted: Bool

    /// The Matrix user ID whose mention pill should be rendered with the
    /// highlighted style. Set by the mapper when ``isHighlighted`` is `true`
    /// so that the view layer can apply the highlight without depending on
    /// an asynchronously configured environment value.
    public var highlightedMentionUserId: String?

    /// Notification keywords that matched this message body. Stored at
    /// mapping time so the view layer can render keyword pills without
    /// depending on an asynchronously configured environment value.
    public var highlightKeywords: [String]

    /// Reply context, present when this message is a reply to another message.
    public var replyDetail: ReplyDetail?

    /// Whether this message has been edited since it was originally sent.
    public var isEdited: Bool

    /// The delivery state of this message, if it is an outgoing local echo.
    ///
    /// `nil` for incoming messages and outgoing messages that have already been
    /// confirmed by the server (i.e. they have an event ID rather than a
    /// transaction ID). When non-nil, the UI displays a sending indicator
    /// or error badge next to the message.
    public var sendState: SendState?

    /// The event ID of the thread root, if this message belongs to a thread.
    ///
    /// Present on thread replies. Used by the SDK to propagate `m.thread`
    /// relations when the user replies to a threaded message.
    public var threadRootEventID: String?

    /// The replies this message has gathered as a thread root, if any.
    public var threadSummary: ThreadSummary?

    /// A shared place, for a message of kind ``Kind/location``.
    public var location: Location?

    /// A poll, for a message of kind ``Kind/poll``.
    public var poll: Poll?

    /// A shared place. Plic shows it as text and an Open in Maps button:
    /// drawing a map would send the coordinates to a tile server unasked.
    public struct Location: Sendable, Equatable {
        /// The `geo:` URI as sent.
        public let geoURI: String
        /// What the sender called the place, if anything.
        public let description: String?

        nonisolated public init(geoURI: String, description: String?) {
            self.geoURI = geoURI
            self.description = description
        }

        /// Latitude and longitude parsed from the URI, when it has them.
        nonisolated public var coordinates: (latitude: Double, longitude: Double)? {
            guard geoURI.lowercased().hasPrefix("geo:") else { return nil }
            let numbers = geoURI.dropFirst(4).split(separator: ";").first?
                .split(separator: ",").compactMap { Double($0) } ?? []
            guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
            return (numbers[0], numbers[1])
        }
    }

    /// A poll and its state, as the sender's event and the votes so far say.
    public struct Poll: Sendable, Equatable {
        public struct Answer: Sendable, Equatable, Identifiable {
            public let id: String
            public let text: String
            /// Voters for this answer. Empty while an undisclosed poll runs.
            public let voterIDs: [String]

            nonisolated public init(id: String, text: String, voterIDs: [String]) {
                self.id = id
                self.text = text
                self.voterIDs = voterIDs
            }
        }

        public let question: String
        public let answers: [Answer]
        /// How many answers one voter may pick.
        public let maxSelections: Int
        /// Whether results are visible while the poll runs.
        public let isDisclosed: Bool
        /// When the poll was ended, if it was.
        public let endedAt: Date?

        nonisolated public init(question: String, answers: [Answer], maxSelections: Int, isDisclosed: Bool, endedAt: Date?) {
            self.question = question
            self.answers = answers
            self.maxSelections = maxSelections
            self.isDisclosed = isDisclosed
            self.endedAt = endedAt
        }

        public var hasEnded: Bool { endedAt != nil }
        /// Whether counts may be shown: a disclosed poll always, another once ended.
        public var showsResults: Bool { isDisclosed || hasEnded }
        public var totalVotes: Int { answers.reduce(0) { $0 + $1.voterIDs.count } }

        /// The answers a user picked.
        nonisolated public func selections(of userId: String?) -> Set<String> {
            guard let userId else { return [] }
            return Set(answers.filter { $0.voterIDs.contains(userId) }.map(\.id))
        }
    }

    /// What a thread root shows of its thread: how many replies, and who
    /// wrote the last one.
    public struct ThreadSummary: Sendable, Equatable {
        public let replyCount: Int
        public let latestSenderName: String?

        nonisolated public init(replyCount: Int, latestSenderName: String?) {
            self.replyCount = replyCount
            self.latestSenderName = latestSenderName
        }
    }

    /// Creates a new ``TimelineMessage`` value.
    ///
    /// - Parameters:
    ///   - id: The stable unique identifier (from the SDK's `uniqueId()`).
    ///   - eventID: The Matrix event ID or transaction ID for SDK operations.
    ///     Defaults to `id` when not provided (e.g. in previews).
    ///   - senderID: The sender's Matrix user ID.
    ///   - senderDisplayName: The sender's display name.
    ///   - senderAvatarURL: The sender's avatar URL.
    ///   - body: The message body text.
    ///   - attributedBody: Rich-text body with link attributes for system events.
    ///   - formattedBody: The HTML-formatted body, if available.
    ///   - timestamp: The time the message was sent.
    ///   - isOutgoing: Whether the current user sent this message.
    ///   - kind: The content type. Defaults to `.text`.
    ///   - mediaInfo: Media attachment metadata, if applicable.
    ///   - reactions: Aggregated reactions. Defaults to an empty array.
    ///   - isHighlighted: Whether the message mentions the current user.
    ///   - highlightedMentionUserId: The user ID whose mention pill should be highlighted.
    ///   - highlightKeywords: Notification keywords that matched this message body.
    ///   - replyDetail: Reply context, if this is a reply.
    ///   - isEdited: Whether the message has been edited. Defaults to `false`.
    ///   - sendState: The delivery state for outgoing messages. Defaults to `nil`.
    ///   - threadRootEventID: The thread root event ID, if this is a thread reply.
    nonisolated public init(
        id: String,
        eventID: String? = nil,
        senderID: String,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        body: String,
        attributedBody: AttributedString? = nil,
        formattedBody: String? = nil,
        timestamp: Date,
        isOutgoing: Bool,
        kind: Kind = .text,
        mediaInfo: MediaInfo? = nil,
        reactions: [ReactionGroup] = [],
        isHighlighted: Bool = false,
        highlightedMentionUserId: String? = nil,
        highlightKeywords: [String] = [],
        replyDetail: ReplyDetail? = nil,
        isEdited: Bool = false,
        sendState: SendState? = nil,
        threadRootEventID: String? = nil,
        threadSummary: ThreadSummary? = nil,
        location: Location? = nil,
        poll: Poll? = nil
    ) {
        self.id = id
        self.eventID = eventID ?? id
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.body = body
        self.attributedBody = attributedBody
        self.formattedBody = formattedBody
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.mediaInfo = mediaInfo
        self.reactions = reactions
        self.isHighlighted = isHighlighted
        self.highlightedMentionUserId = highlightedMentionUserId
        self.highlightKeywords = highlightKeywords
        self.replyDetail = replyDetail
        self.isEdited = isEdited
        self.sendState = sendState
        self.threadRootEventID = threadRootEventID
        self.threadSummary = threadSummary
        self.location = location
        self.poll = poll
    }

    /// The best available display name for the sender, falling back to the Matrix user ID.
    nonisolated public var displayName: String {
        senderDisplayName ?? senderID
    }

    /// The message timestamp formatted as a short time string (e.g. `"2:30 PM"`).
    nonisolated public var formattedTime: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }

    /// Whether this message is a non-text type that requires special rendering (media, redacted, encrypted, etc.).
    nonisolated public var isSpecialType: Bool {
        switch kind {
        case .text, .emote, .notice: false
        case .membership, .profileChange, .stateEvent, .callEvent: false
        default: true
        }
    }

    /// Whether this item represents a system event (membership change, profile update, or room state change)
    /// rather than a user-authored message.
    nonisolated public var isSystemEvent: Bool {
        switch kind {
        case .membership, .profileChange, .stateEvent, .callEvent: true
        default: false
        }
    }
}
