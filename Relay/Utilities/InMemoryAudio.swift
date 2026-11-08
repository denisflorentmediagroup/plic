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

import AudioToolbox
import AVFoundation

/// Decodes audio held in memory, without ever writing it to disk.
///
/// `AVAudioFile` only reads files, so a received voice message used to be
/// written out decrypted before it could play. Core Audio's callback API
/// reads the same formats — Ogg Opus included — from bytes in memory, and the
/// result is decoded PCM that plays from a buffer.
nonisolated enum InMemoryAudio {
    enum DecodingError: Error {
        /// Core Audio could not open or read the data, with its status.
        case unreadable(OSStatus)
        /// The data opened but held no audio.
        case empty
        /// The audio would decode to more than ``maximumSamples``.
        case tooLong
    }

    /// The most samples a decode may produce, across channels: twenty minutes
    /// of mono at 48 kHz, about 230 MB as floats. A few compressed megabytes
    /// — silence, at a high sample rate — would otherwise expand to gigabytes,
    /// and a voice message decodes as soon as it is shown.
    static let maximumSamples = 57_600_000

    /// Frames decoded per read while filling the result.
    private static let chunkFrames: AVAudioFrameCount = 32_768

    /// All of `data`, decoded to deinterleaved 32-bit float PCM at its own
    /// sample rate and channel count.
    ///
    /// Blocking, and proportional to the audio's length: call it off the main
    /// actor.
    static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        let source = Unmanaged.passRetained(MemorySource(data))
        defer { source.release() }

        var audioFile: AudioFileID?
        var status = AudioFileOpenWithCallbacks(source.toOpaque(), read, nil, size, nil, 0, &audioFile)
        guard status == noErr, let audioFile else { throw DecodingError.unreadable(status) }
        defer { AudioFileClose(audioFile) }

        var extFile: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(audioFile, false, &extFile)
        guard status == noErr, let extFile else { throw DecodingError.unreadable(status) }
        defer { ExtAudioFileDispose(extFile) }

        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &formatSize, &fileFormat)
        guard status == noErr, fileFormat.mSampleRate > 0, fileFormat.mChannelsPerFrame > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: fileFormat.mSampleRate,
                  channels: fileFormat.mChannelsPerFrame, interleaved: false
              )
        else { throw DecodingError.unreadable(status) }

        var clientFormat = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(
            extFile, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
        )
        guard status == noErr else { throw DecodingError.unreadable(status) }

        // Read until the decoder runs dry: the length a compressed stream
        // declares can be an estimate.
        var chunks: [AVAudioPCMBuffer] = []
        var total: AVAudioFrameCount = 0
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw DecodingError.empty
            }
            // The buffer list advertises frameLength frames of room; make it
            // the whole capacity before Core Audio writes into it.
            chunk.frameLength = chunk.frameCapacity
            var frames = chunk.frameCapacity
            status = ExtAudioFileRead(extFile, &frames, chunk.mutableAudioBufferList)
            guard status == noErr else { throw DecodingError.unreadable(status) }
            if frames == 0 { break }
            chunk.frameLength = frames
            let (sum, overflowed) = total.addingReportingOverflow(frames)
            guard !overflowed, Int(sum) * Int(format.channelCount) <= Self.maximumSamples else {
                throw DecodingError.tooLong
            }
            chunks.append(chunk)
            total = sum
        }

        guard total > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let target = result.floatChannelData
        else { throw DecodingError.empty }
        var offset = 0
        for chunk in chunks {
            guard let samples = chunk.floatChannelData else { continue }
            for channel in 0..<Int(format.channelCount) {
                (target[channel] + offset).update(from: samples[channel], count: Int(chunk.frameLength))
            }
            offset += Int(chunk.frameLength)
        }
        result.frameLength = total
        return result
    }

    /// Decodes off the calling actor, for callers on the main actor.
    ///
    /// The buffer is created inside the task and handed over whole, never
    /// shared, so it crosses to the caller safely.
    static func decodeInBackground(_ data: Data) async -> sending AVAudioPCMBuffer? {
        let handoff = await Task.detached(priority: .userInitiated) {
            Handoff(buffer: try? decode(data))
        }.value
        return handoff.buffer
    }

    private struct Handoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer?
    }

    /// The frames of `buffer` from `start` to its end, as a new buffer — what
    /// a player node needs to begin playing partway through.
    static func tail(of buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let length = AVAudioFramePosition(buffer.frameLength)
        guard start >= 0, start < length,
              let source = buffer.floatChannelData,
              let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length - start)),
              let target = tail.floatChannelData
        else { return nil }
        let count = Int(length - start)
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + Int(start), count: count)
        }
        tail.frameLength = AVAudioFrameCount(count)
        return tail
    }

    // MARK: - Core Audio callbacks

    /// The bytes Core Audio reads through the callbacks below.
    private final class MemorySource {
        let data: Data
        init(_ data: Data) { self.data = data }
    }

    private static let read: AudioFile_ReadProc = { clientData, position, requested, buffer, actual in
        let data = Unmanaged<MemorySource>.fromOpaque(clientData).takeUnretainedValue().data
        guard position >= 0, position < Int64(data.count) else {
            actual.pointee = 0
            return noErr
        }
        let count = min(Int(requested), data.count - Int(position))
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                buffer.copyMemory(from: base + Int(position), byteCount: count)
            }
        }
        actual.pointee = UInt32(count)
        return noErr
    }

    private static let size: AudioFile_GetSizeProc = { clientData in
        Int64(Unmanaged<MemorySource>.fromOpaque(clientData).takeUnretainedValue().data.count)
    }
}
