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

/// A page the homeserver can host for managing the signed-in account.
///
/// Mirrors the subset of the SDK's `AccountManagementAction` that Plic uses.
/// Declared here rather than re-exported because this package deliberately has
/// no SDK dependency — that is what lets Xcode previews import it without
/// loading the Rust binary. ``MatrixService`` translates between the two.
public enum AccountAction: Sendable, Equatable {
    /// The account's profile page.
    case profile

    /// The signed-in devices list.
    case devices

    /// The page that signs out one device.
    case deviceDelete(deviceId: String)

    /// The deactivation page.
    ///
    /// App Store guideline 5.1.1(v) requires an app offering account creation
    /// to offer deletion too. On Matrix the account belongs to the homeserver,
    /// so the honest implementation sends the user there rather than
    /// pretending the client can delete it.
    case deactivate
}
