# ``RelayKit``

The SDK layer for Relay, providing SwiftUI-native bindings for the Matrix
Rust SDK and Relay-specific service implementations.

## Overview

RelayKit wraps the Matrix Rust SDK's UniFFI-generated types in `@Observable`
proxy classes, making them suitable for direct use in SwiftUI. Each SDK type
gets a **Protocol + Proxy** pair: the protocol defines the public API, and
the proxy class implements it by wrapping the underlying SDK object.

The framework bridges the SDK's callback-based listener interfaces to
Swift's `AsyncStream`, enabling consumption via `.task { for await ... }` in
SwiftUI. It also provides Relay's concrete service implementations
(`MatrixService`, `TimelineViewModel`, etc.) that consume these proxies.

### Quick Example

```swift
// Build a client
let client = try await ClientBuilderProxy()
    .serverNameOrHomeserverUrl("matrix.org")
    .sessionPaths(dataPath: dataDir, cachePath: cacheDir)
    .build()

// Authenticate
try await client.login(
    username: "alice",
    password: "secret",
    initialDeviceName: "My App",
    deviceId: nil
)

// Start sync
let syncService = try await SyncServiceBuilderProxy(builder: client.syncService())
    .build()
await syncService.start()
```

## Topics

### Articles
- <doc:Architecture>

### Core Infrastructure
- ``SDKListener``
- ``AsyncStreamBridge``
- ``DiffEngine``
- ``DiffOperation``

### Client
- ``ClientProxy``
- ``ClientBuilderProxy``
- ``ClientProxyProtocol``

### Sync
- ``SyncServiceBuilderProxy``
- ``RoomListServiceProxy``
- ``RoomListProxy``

### Rooms

### Timeline
- ``TimelineProxy``
- ``TimelineItemProvider``

### Room List
- ``RoomSummary``
- ``RoomSummaryProvider``

### Encryption
- ``UserIdentityProxy``

### Verification
- ``SessionVerificationControllerProxy``
- ``SessionVerificationFlowState``

### Notifications
- ``NotificationClientProxy``

### Other Services
- ``SpaceServiceProxy``
- ``RoomDirectorySearchProxy``
- ``ThreadListServiceProxy``
- ``MediaProxy``
- ``RoomPreviewProxy``
