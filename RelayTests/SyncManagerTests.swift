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

import MatrixRustSDK
import Testing

@testable import RelayKit

/// Pins the sync state machine: what each phase does with each input, and
/// how long it waits before trying again.
struct SyncManagerTests {
    private typealias Phase = SyncManager.LifecyclePhase
    private typealias Input = SyncManager.ConnectivityInput
    private typealias Action = SyncManager.Action

    private func action(_ phase: Phase, _ input: Input) -> Action {
        SyncManager.action(for: input, in: phase)
    }

    @Test("Active: the network or the Mac going away stops sync; the SDK giving up retries")
    func active() {
        #expect(action(.active, .networkOffline) == .tearDownForOffline)
        #expect(action(.active, .systemWillSleep) == .tearDownForSleep)
        #expect(action(.active, .sdkState(.running)) == .publishRunning)
        #expect(action(.active, .sdkState(.idle)) == .ignore)
        #expect(action(.active, .sdkState(.offline)) == .tearDownForOfflineAndReconnect)
        #expect(action(.active, .sdkState(.error)) == .tearDownForOfflineAndReconnect)
        #expect(action(.active, .sdkState(.terminated)) == .publishTerminated(backToActive: false))
        #expect(action(.active, .networkOnline) == .ignore)
        #expect(action(.active, .reconnectTimerFired) == .ignore)
    }

    @Test("Sleeping: only waking rebuilds; a network loss is remembered for the banner")
    func sleeping() {
        #expect(action(.sleeping, .systemDidWake) == .rebuildAfterWake)
        #expect(action(.sleeping, .networkOffline) == .goOffline)
        #expect(action(.sleeping, .networkOnline) == .ignore)
        #expect(action(.sleeping, .sdkState(.error)) == .ignore)
        #expect(action(.sleeping, .reconnectTimerFired) == .ignore)
    }

    @Test("Offline: the network returning or the timer firing rebuilds; nothing else does")
    func offline() {
        #expect(action(.offline, .networkOnline) == .rebuildAfterOnline)
        #expect(action(.offline, .reconnectTimerFired) == .rebuildAfterOnline)
        #expect(action(.offline, .networkOffline) == .ignore)
        #expect(action(.offline, .sdkState(.running)) == .ignore)
        #expect(action(.offline, .systemDidWake) == .ignore)
    }

    @Test("Rebuilding: SDK errors are left to the rebuild; the network and sleep still win")
    func rebuilding() {
        #expect(action(.rebuilding, .sdkState(.running)) == .publishRunning)
        #expect(action(.rebuilding, .sdkState(.error)) == .suppressDuringRebuild)
        #expect(action(.rebuilding, .sdkState(.offline)) == .suppressDuringRebuild)
        #expect(action(.rebuilding, .sdkState(.terminated)) == .publishTerminated(backToActive: true))
        #expect(action(.rebuilding, .networkOffline) == .tearDownForOffline)
        #expect(action(.rebuilding, .systemWillSleep) == .tearDownForSleep)
        #expect(action(.rebuilding, .reconnectTimerFired) == .ignore)
    }

    @Test("Pending restore: only the network coming back retries the restore")
    func pendingRestore() {
        #expect(action(.pendingRestore, .networkOnline) == .retryPendingRestore)
        #expect(action(.pendingRestore, .networkOffline) == .ignore)
        #expect(action(.pendingRestore, .sdkState(.running)) == .ignore)
        #expect(action(.pendingRestore, .systemDidWake) == .ignore)
    }

    @Test("Idle ignores everything")
    func idle() {
        #expect(action(.idle, .networkOnline) == .ignore)
        #expect(action(.idle, .sdkState(.running)) == .ignore)
        #expect(action(.idle, .systemWillSleep) == .ignore)
    }

    @Test("The reconnect window doubles from one slot and stops at the cap")
    func backoff() {
        #expect(SyncManager.reconnectWindow(attempt: 0, maxExponent: 6) == 1)
        #expect(SyncManager.reconnectWindow(attempt: 1, maxExponent: 6) == 2)
        #expect(SyncManager.reconnectWindow(attempt: 3, maxExponent: 6) == 8)
        #expect(SyncManager.reconnectWindow(attempt: 6, maxExponent: 6) == 64)
        #expect(SyncManager.reconnectWindow(attempt: 40, maxExponent: 6) == 64)
        #expect(SyncManager.reconnectWindow(attempt: -1, maxExponent: 6) == 1)
    }
}
