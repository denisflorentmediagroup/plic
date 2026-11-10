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

import RelayInterface
import SwiftUI

// MARK: - View Model

@Observable
final class SessionsSettingsViewModel {
    var devices: [DeviceInfo] = []
    var isSessionVerified = false
    var isLoading = true
    var errorReporter: ErrorReporter?

    @MainActor
    func load(service: any MatrixServiceProtocol) async {
        do {
            devices = try await service.getDevices().sorted(by: Self.deviceOrder)
            isSessionVerified = await service.isCurrentSessionVerified()
        } catch {
            errorReporter?.report(.sessionsFailed(error.localizedDescription))
        }
        isLoading = false
    }

    nonisolated static func deviceOrder(_ lhs: DeviceInfo, _ rhs: DeviceInfo) -> Bool {
        if lhs.isCurrentDevice { return true }
        if rhs.isCurrentDevice { return false }
        // swiftlint:disable:next identifier_name
        if let l = lhs.lastSeenTimestamp, let r = rhs.lastSeenTimestamp { return l > r }
        if lhs.lastSeenTimestamp != nil { return true }
        if rhs.lastSeenTimestamp != nil { return false }
        return lhs.id < rhs.id
    }
}

// MARK: - Verification Item

/// A wrapper that gives a session verification view model an `Identifiable`
/// identity for use with `.sheet(item:)`.
struct VerificationItem: Identifiable {
    let id = UUID()
    let viewModel: any SessionVerificationViewModelProtocol
}

// MARK: - Sessions Tab

/// The Sessions tab of the Settings window, listing the current device, other
/// active sessions, and providing a button to start cross-device verification.
struct SettingsSessionsTab: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @State private var viewModel = SessionsSettingsViewModel()
    @State private var verificationItem: VerificationItem?
    @State private var pendingSignOut: PendingSignOut?
    @State private var passwordRequest: PendingSignOut?

    var body: some View {
        Form {
            if viewModel.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } else if viewModel.devices.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "desktopcomputer",
                        description: Text("No device information is available.")
                    )
                }
            } else {
                let current = viewModel.devices.filter(\.isCurrentDevice)
                let others = viewModel.devices.filter { !$0.isCurrentDevice }

                if let device = current.first {
                    Section("Current Session") {
                        DeviceRow(device: device, isVerified: viewModel.isSessionVerified)
                    }
                }

                if others.count > 0 {
                    Section {
                        Button {
                            Task {
                                do {
                                    // swiftlint:disable:next identifier_name
                                    if let vm = try await matrixService.makeSessionVerificationViewModel() {
                                        verificationItem = VerificationItem(viewModel: vm)
                                    }
                                } catch {
                                    errorReporter.report(.verificationFailed(error.localizedDescription))
                                }
                            }
                        } label: {
                            Label("Verify Session", systemImage: "checkmark.shield")
                        }
                    } footer: {
                        Text("Verify using another device or your security key.")
                    }
                }

                if !others.isEmpty {
                    Section {
                        ForEach(others) { device in
                            DeviceRow(device: device)
                                .contextMenu {
                                    Button("Sign Out…", role: .destructive) {
                                        pendingSignOut = PendingSignOut(deviceIds: [device.id], name: device.displayName ?? device.id)
                                    }
                                }
                        }
                        Button("Sign Out All Other Sessions…", role: .destructive) {
                            pendingSignOut = PendingSignOut(deviceIds: others.map(\.id), name: nil)
                        }
                    } header: {
                        Text("Other Sessions")
                    } footer: {
                        Text("Right-click a session to sign it out. A session you do not recognise should go: it can read what you can.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            viewModel.errorReporter = errorReporter
            await viewModel.load(service: matrixService)
        }
        .sheet(item: $verificationItem) { item in
            VerificationSheet(viewModel: item.viewModel)
        }
        .confirmationDialog(
            pendingSignOut?.name.map { "Sign out “\($0)”?" } ?? "Sign out all other sessions?",
            isPresented: Binding(get: { pendingSignOut != nil }, set: { if !$0 { pendingSignOut = nil } }),
            titleVisibility: .visible,
            presenting: pendingSignOut
        ) { request in
            Button("Sign Out", role: .destructive) { signOut(request, password: nil) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.name == nil
                 ? "Every session but this one will have to sign in again. Their encrypted history stays readable here, and in key backup."
                 : "That session will have to sign in again.")
        }
        .sheet(item: $passwordRequest) { request in
            PasswordForSignOutSheet { password in
                signOut(request, password: password)
            }
        }
    }

    /// Signs devices out, handling the three answers a server can give.
    private func signOut(_ request: PendingSignOut, password: String?) {
        Task {
            do {
                switch try await matrixService.signOutDevices(ids: request.deviceIds, password: password) {
                case .signedOut:
                    await viewModel.load(service: matrixService)
                case .passwordRequired:
                    passwordRequest = request
                case .managedElsewhere(let url):
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
            } catch {
                errorReporter.report(.sessionsFailed(error.localizedDescription))
            }
        }
    }
}

/// Devices the user asked to sign out, awaiting confirmation or a password.
private struct PendingSignOut: Identifiable {
    let deviceIds: [String]
    /// The device's name for a single one; `nil` for all the others.
    let name: String?
    var id: String { deviceIds.joined(separator: ",") }
}

/// Asks for the account password a homeserver may require before signing
/// out devices. The password goes to that server once and is kept nowhere.
private struct PasswordForSignOutSheet: View {
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm Your Password", systemImage: "lock")
                .font(.title3.bold())
            Text("Your homeserver asks for the account password before signing out a session. Plic sends it to the server once and does not keep it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(send)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign Out", role: .destructive, action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFieldFocused = true }
    }

    private func send() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""
        dismiss()
        submit(entered)
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: DeviceInfo
    var isVerified: Bool?

    private var iconName: String {
        if device.isCurrentDevice {
            return (isVerified == true) ? "checkmark.shield.fill" : "xmark.shield.fill"
        }
        return "desktopcomputer"
    }

    private var iconColor: Color {
        if device.isCurrentDevice {
            return (isVerified == true) ? .green : .red
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName ?? "Unknown device")
                        .fontWeight(.medium)
                    if device.isCurrentDevice {
                        Text("This device")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text(device.id)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    if let ts = device.lastSeenTimestamp {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(ts, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // swiftlint:disable:next identifier_name
                if let ip = device.lastSeenIP {
                    Text(ip)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TabView {
        SettingsSessionsTab()
            .tabItem { Label("Sessions", systemImage: "desktopcomputer") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
