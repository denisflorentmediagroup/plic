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


import RelayInterface
import SwiftUI

/// The Encryption tab of the Settings window: session verification, key
/// backup and account recovery, with the actions that change them.
///
/// Without a recovery key, an account whose every session is lost loses
/// its encrypted history with them. Setting recovery up is therefore
/// offered here rather than merely reported as missing.
struct SettingsEncryptionTab: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @State private var isSessionVerified = false
    @State private var status = EncryptionStatus()
    @State private var isWorking = false
    @State private var newRecoveryKey: RecoveryKeyPresentation?
    @State private var isEnteringRecoveryKey = false

    var body: some View {
        Form {
            Section {
                SecurityStatusRow(
                    icon: isSessionVerified ? "checkmark.shield.fill" : "xmark.shield.fill",
                    color: isSessionVerified ? .green : .red,
                    title: isSessionVerified ? "Session Verified" : "Session Not Verified",
                    detail: isSessionVerified
                        ? "This device has been verified by another session."
                        : "Verify this session from another device to enable cross-signing."
                )
            } header: {
                Text("Identity Verification")
                // swiftlint:disable:next line_length
                Text("Allows you to verify other Matrix accounts and automatically trust their verified sessions.")
            }

            Section {
                SecurityStatusRow(
                    // swiftlint:disable:next line_length
                    icon: status.backupEnabled ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath",
                    color: status.backupEnabled ? .green : .orange,
                    title: status.backupEnabled ? "Key Backup Enabled" : "Key Backup Not Active",
                    detail: status.backupEnabled
                        ? "Message keys are being backed up to the server, encrypted with your recovery key."
                        : "Message keys are not being backed up. A new session could not read your history."
                )
                if !status.backupEnabled && status.recovery == .enabled {
                    Button("Enable Key Backup") {
                        perform { try await matrixService.enableKeyBackup() }
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("Key Backup")
            }

            Section {
                SecurityStatusRow(
                    icon: status.recovery == .enabled ? "key.fill" : "key",
                    color: recoveryColor,
                    title: recoveryTitle,
                    detail: recoveryDetail
                )
                recoveryActions
            } header: {
                Text("Account Recovery")
                // swiftlint:disable:next line_length
                Text("A recovery key lets a new session read your encrypted history when every other session is gone. Plic never sees it; keep it somewhere safe, outside this Mac.")
            }
        }
        .formStyle(.grouped)
        .task { await loadState() }
        .sheet(item: $newRecoveryKey) { key in
            RecoveryKeySheet(recoveryKey: key.value) {
                newRecoveryKey = nil
                Task { await loadState() }
            }
        }
        .sheet(isPresented: $isEnteringRecoveryKey) {
            EnterRecoveryKeySheet { key in
                try await matrixService.recover(recoveryKey: key)
                await loadState()
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        switch status.recovery {
        case .disabled:
            Button("Set Up Recovery…") {
                perform {
                    let key = try await matrixService.enableRecovery()
                    newRecoveryKey = RecoveryKeyPresentation(value: key)
                }
            }
            .disabled(isWorking)
        case .incomplete:
            Button("Enter Recovery Key…") { isEnteringRecoveryKey = true }
                .disabled(isWorking)
        case .enabled:
            Button("Reset Recovery Key…") {
                perform {
                    let key = try await matrixService.resetRecoveryKey()
                    newRecoveryKey = RecoveryKeyPresentation(value: key)
                }
            }
            .disabled(isWorking)
        case .unknown:
            EmptyView()
        }
    }

    private var recoveryColor: Color {
        switch status.recovery {
        case .enabled: .green
        case .incomplete: .orange
        case .disabled: .red
        case .unknown: .secondary
        }
    }

    private var recoveryTitle: String {
        switch status.recovery {
        case .enabled: "Recovery Enabled"
        case .incomplete: "Recovery Key Needed"
        case .disabled: "Recovery Not Set Up"
        case .unknown: "Checking Recovery…"
        }
    }

    private var recoveryDetail: String {
        switch status.recovery {
        case .enabled: "You can recover your encrypted messages on a new session with your recovery key."
        case .incomplete: "Recovery was set up on another session. Enter the key here so this one can read backed-up history."
        case .disabled: "If every session of this account were lost, so would its encrypted history. A recovery key prevents that."
        case .unknown: ""
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await work()
            } catch {
                errorReporter.report(.verificationFailed(error.localizedDescription))
            }
            await loadState()
            isWorking = false
        }
    }

    private func loadState() async {
        isSessionVerified = await matrixService.isCurrentSessionVerified()
        status = await matrixService.encryptionState()
    }
}

/// A freshly made recovery key, wrapped so a sheet can present it.
private struct RecoveryKeyPresentation: Identifiable {
    let value: String
    var id: String { value }
}

/// Shows a recovery key once, to be copied or written down.
private struct RecoveryKeySheet: View {
    let recoveryKey: String
    let done: () -> Void
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your Recovery Key", systemImage: "key.fill")
                .font(.title3.bold())
            Text("Write it down or store it in a password manager. Plic does not keep a copy and cannot show it again. Anyone with this key can read your encrypted history, so keep it to yourself.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(recoveryKey)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            HStack {
                Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryKey, forType: .string)
                    didCopy = true
                }
                Spacer()
                Button("I’ve Saved It", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Asks for a recovery key made on another session.
private struct EnterRecoveryKeySheet: View {
    let recover: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var isWorking = false
    @State private var failure: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Enter Recovery Key", systemImage: "key")
                .font(.title3.bold())
            Text("The key you saved when recovery was set up on another session. It unlocks the backed-up message keys for this one.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Recovery key", text: $key, prompt: Text("EsTx xxxx xxxx …"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                .onSubmit(submit)
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Recover", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { isFieldFocused = true }
    }

    private func submit() {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            do {
                try await recover(key)
                dismiss()
            } catch {
                failure = "That key did not unlock the backup. Check it and try again."
                isWorking = false
            }
        }
    }
}

#Preview {
    TabView {
        SettingsEncryptionTab()
            .tabItem { Label("Encryption", systemImage: "lock.fill") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
