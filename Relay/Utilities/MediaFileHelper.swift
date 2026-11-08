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

import AppKit
import CryptoKit
import RelayInterface
import UniformTypeIdentifiers

/// Writes received media to disk — only where the user chooses, when they
/// choose to save it — and removes the decrypted copies earlier builds left
/// in the temporary directory.
///
/// Viewing and playing never involve a file: see ``MediaViewer``,
/// ``InMemoryAudio`` and ``InMemoryAsset``.
enum MediaFileHelper {

    // MARK: - Decrypted Copies

    /// The prefix Plic 0.5.33 gave the decrypted copies it wrote for Quick Look
    /// and the players. Left behind they are the conversation itself, in the
    /// clear, readable by anything with the disk.
    nonisolated static let decryptedFilePrefix = "decrypted-"

    /// Deletes every plaintext copy left in `directory`: the decrypted copies
    /// earlier builds wrote — the prefixed names of 0.5.33, and the unprefixed
    /// ones before it (sixteen hex digits and a dash) — and the copies made of
    /// outgoing attachments while they were staged, which nothing can still be
    /// sending at launch. Called at launch.
    ///
    /// - Returns: How many files were removed.
    @discardableResult
    nonisolated static func removeDecryptedFiles(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where isDecryptedCopy(name) {
            if (try? FileManager.default.removeItem(at: directory.appending(path: name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    nonisolated static func isDecryptedCopy(_ name: String) -> Bool {
        if name.hasPrefix(decryptedFilePrefix) { return true }
        // Legacy: `<16 hex digits>-<name>` from before the prefix existed.
        let head = name.prefix(17)
        if head.count == 17 && head.last == "-" && head.dropLast().allSatisfy(\.isHexDigit) { return true }
        return isStagedCopy(name)
    }

    /// A copy of an attachment being sent: `<UUID>-<name>`, as the compose
    /// bar writes them. Deleted after sending, and here if that never came.
    nonisolated static func isStagedCopy(_ name: String) -> Bool {
        let head = name.prefix(37)
        guard head.count == 37, head.last == "-" else { return false }
        return UUID(uuidString: String(head.dropLast())) != nil
    }

    /// Downloads media content and presents an NSSavePanel for saving to disk.
    ///
    /// - Parameters:
    ///   - mediaInfo: The media metadata containing the MXC URL and filename.
    ///   - matrixService: The service used to download media content.
    ///   - contentTypes: The allowed content types for the save panel.
    ///   - data: Pre-downloaded data to use instead of fetching. Pass `nil` to download.
    ///   - message: Shown in the panel, to say why it appeared.
    /// - Throws: If the media cannot be downloaded or written.
    static func saveToFile(
        mediaInfo: TimelineMessage.MediaInfo,
        matrixService: any MatrixServiceProtocol,
        contentTypes: [UTType],
        data existingData: Data? = nil,
        message: String? = nil
    ) async throws {
        let data: Data
        if let existingData {
            data = existingData
        } else {
            guard let downloaded = await matrixService.mediaContent(
                mxcURL: mediaInfo.mxcURL,
                mediaSourceJSON: mediaInfo.mediaSourceJSON
            ) else {
                throw MediaFileError.downloadFailed
            }
            data = downloaded
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = mediaInfo.filename
        if let message { panel.message = message }
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url)
    }

    /// Errors specific to media file operations.
    enum MediaFileError: LocalizedError {
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "Failed to download media content."
            }
        }
    }
}
