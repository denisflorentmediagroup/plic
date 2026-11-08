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

@testable import Relay

/// Pins that the plaintext copies Plic leaves in the temporary directory —
/// decrypted media from earlier builds, staged attachments never sent — are
/// found and removed at launch, and that nothing else is.
struct DecryptedFileCleanupTests {

    private func scratch() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "plic-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ directory: URL, _ name: String) throws {
        try Data("x".utf8).write(to: directory.appending(path: name))
    }

    @Test("Decrypted and staged copies go, current and legacy names alike; nothing else does")
    func removesOnlyDecryptedCopies() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir, "decrypted-46cb4f7ee9ba69b9-voice.ogg")     // 0.5.33
        try touch(dir, "9c5c92e86244bd94-voice message.ogg")      // earlier builds: never deleted
        try touch(dir, "voice-3F2504E0-4F89-11D3-9A0C-0305E82C3301.ogg")          // a recording in progress
        try touch(dir, "3F2504E0-4F89-11D3-9A0C-0305E82C3301-report.pdf")         // staged, then forgotten
        try touch(dir, "3F2504E0-4F89-11D3-9A0C-0305E82C3301-Pasted Image.png")   // pasted, then forgotten
        try touch(dir, "unrelated.txt")

        let removed = MediaFileHelper.removeDecryptedFiles(in: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        #expect(removed == 4)
        #expect(left == [
            "unrelated.txt",
            "voice-3F2504E0-4F89-11D3-9A0C-0305E82C3301.ogg",
        ])
    }
}
