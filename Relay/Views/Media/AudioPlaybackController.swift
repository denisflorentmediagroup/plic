// Copyright 2026 Denis Florent
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

import AVFoundation
import Observation
import SwiftUI

/// Plays a single audio attachment, decoded in memory, and publishes its
/// progress.
///
/// Built on `AVAudioEngine` rather than `AVAudioPlayer`. The simpler class
/// cannot seek inside Ogg/Opus — the format Matrix voice messages arrive in: it
/// accepts a new `currentTime`, reads it back correctly, and then restarts the
/// decoder from zero. Scheduling a segment on an `AVAudioPlayerNode` seeks to an
/// exact frame instead.
@MainActor
@Observable
final class AudioPlaybackController {

    /// Whether audio is currently coming out of the speakers.
    private(set) var isPlaying = false

    /// Playhead position in seconds. Updated about ten times a second while playing.
    private(set) var currentTime: TimeInterval = 0

    /// Track length in seconds, or `0` before anything is loaded.
    private(set) var duration: TimeInterval = 0

    /// Set when the audio could not be decoded, so the view can stop offering playback.
    private(set) var failed = false

    /// Whether audio has been loaded and can be played.
    var isLoaded: Bool { buffer != nil }

    /// Progress from 0 to 1, or `0` when nothing is loaded.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// The whole track, decoded. Held in memory only — the attachment is
    /// never written to disk to be played.
    private var buffer: AVAudioPCMBuffer?
    private var sampleRate: Double = 44_100

    /// Where the current segment started. `AVAudioPlayerNode` counts sample time
    /// from the start of what it was handed, not from the start of the track, so
    /// every reported position is relative to this.
    private var segmentStart: TimeInterval = 0

    /// Bumped on every stop or reschedule. A completion callback carrying a
    /// stale token belongs to a segment the user already seeked away from, and
    /// must not be mistaken for the track finishing.
    private var generation = 0

    /// Polls the node for its playhead while audio is running.
    ///
    /// No `deinit` cancels this: the loop captures `self` weakly and returns as
    /// soon as the controller is gone, and a `deinit` is nonisolated so it could
    /// not touch this property anyway.
    private var ticker: Task<Void, Never>?

    /// Loads decoded audio, replacing anything previously loaded.
    ///
    /// - Parameter buffer: The track, from ``InMemoryAudio/decode(_:)``.
    /// - Returns: `true` if it holds audio that can play.
    @discardableResult
    func load(_ buffer: AVAudioPCMBuffer) -> Bool {
        stop()

        let format = buffer.format
        guard buffer.frameLength > 0, format.sampleRate > 0 else {
            failed = true
            return false
        }

        if node.engine == nil {
            engine.attach(node)
        }
        // Reconnect each time: new audio may have a different sample rate or
        // channel count than the last track this controller played.
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()

        self.buffer = buffer
        sampleRate = format.sampleRate
        duration = Double(buffer.frameLength) / format.sampleRate
        currentTime = 0
        segmentStart = 0
        failed = false
        return true
    }

    /// Starts playback, or pauses it if already playing.
    func togglePlayback() {
        guard buffer != nil else { return }

        if isPlaying {
            node.pause()
            engine.pause()
            isPlaying = false
            ticker?.cancel()
            return
        }

        // Replay from the top once the track has run to the end, so a second
        // click replays rather than doing nothing.
        let resumeAt = currentTime >= duration - 0.05 ? 0 : currentTime
        startPlayback(from: resumeAt)
    }

    /// Moves the playhead to a fraction of the track.
    ///
    /// - Parameter fraction: A value from 0 to 1.
    func seek(toFraction fraction: Double) {
        guard buffer != nil, duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration
        let wasPlaying = isPlaying

        if wasPlaying {
            startPlayback(from: target)
        } else {
            // Paused: move the playhead and let the next play pick it up, rather
            // than starting audio the user did not ask for.
            generation += 1
            node.stop()
            segmentStart = target
            currentTime = target
        }
    }

    /// Stops playback and releases the decoder.
    func stop() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        node.stop()
        if engine.isRunning { engine.stop() }
        buffer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        segmentStart = 0
    }

    /// Schedules the rest of the track from `time` and starts the engine.
    private func startPlayback(from time: TimeInterval) {
        guard let buffer else { return }

        generation += 1
        let token = generation

        node.stop()

        let startFrame = AVAudioFramePosition(time * sampleRate)
        // From the top, the whole buffer; from anywhere else, a copy of what
        // remains — a player node has no way to start partway into a buffer.
        let segment = startFrame <= 0 ? buffer : InMemoryAudio.tail(of: buffer, from: startFrame)
        guard let segment, segment.frameLength > 0 else {
            currentTime = duration
            isPlaying = false
            return
        }

        segmentStart = startFrame <= 0 ? 0 : time
        currentTime = segmentStart

        node.scheduleBuffer(segment, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.ticker?.cancel()
                // A running engine keeps the output device open: it renders
                // silence on an audio thread and holds an assertion that stops
                // the Mac from sleeping when idle. Pausing releases both.
                self.engine.pause()
                self.isPlaying = false
                // Leave the playhead at the end so the waveform reads as complete
                // rather than snapping back the instant the sound stops.
                self.currentTime = self.duration
            }
        }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            failed = true
            isPlaying = false
            return
        }

        node.play()
        isPlaying = true
        startTicking()
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                self.currentTime = self.playheadPosition
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The node's position, translated back into a position in the track.
    private var playheadPosition: TimeInterval {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else { return currentTime }

        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(segmentStart + elapsed, duration)
    }
}
