# Sony Camera Photo Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a cross-platform Sony camera companion whose first release connects Android to a first-generation ZV-E10, browses and filters camera files, previews them, and imports original files through a recoverable queue; then bring the shared product to iOS, macOS, and Windows.

**Architecture:** Flutter/Dart owns the shared application, gallery, format model, and transfer orchestration. A capability-based `CameraAdapter` separates model protocols, while platform adapters own Wi-Fi routing, permission prompts, background execution, and saving files. Implement and validate Android first, then add iOS and desktop integrations without changing gallery behavior.

**Tech Stack:** Flutter stable, Dart, Android Kotlin platform integration, Swift iOS integration, Flutter macOS/Windows targets, REA with JADX and Apktool for static reference-app analysis.

---

## Approved product decisions

- Gallery layout B: large previews; mobile uses two columns and desktop adapts to available width.
- Type filters show concrete formats present on the camera, such as RAW, JPEG, and MP4, with counts; empty types are omitted.
- First implementation target is Android + the user's first-generation ZV-E10. App-wide model support is capability-based and only advertised after validation.
- Preserve original file bytes. Do not silently resize, re-encode, or send photos to a cloud service.
- Transfer intent is durable. Android may keep a user-started transfer active in a connected-device foreground service. On iOS, use background URLSession only for eligible HTTP(S) transfers; otherwise resume the persisted queue when the app returns to the foreground.
- Live monitoring and camera remote control follow the photo transfer milestone.
- Do not add or run automated tests unless the user asks for testing or verification. Use the staged build and device validation steps only after that authorization.

## Repository map

The initial repository contains only the approved design, Git ignore rule, and generated brainstorming artifacts; there is no pre-existing application structure. The following layout is created by this plan:

```text
lib/
  main.dart
  app/
    camera_transfer_app.dart
    app_theme.dart
  domain/
    models/
      camera_capabilities.dart
      camera_file.dart
      camera_page.dart
      camera_profile.dart
      transfer_job.dart
      transfer_progress.dart
    ports/
      camera_adapter.dart
      camera_network.dart
      camera_http_transport.dart
      camera_credential_store.dart
      import_destination.dart
  data/
    adapters/
      sony_zve10_adapter.dart
    persistence/
      transfer_queue_store.dart
      thumbnail_cache.dart
  features/
    connection/
      connection_controller.dart
      connect_screen.dart
    gallery/
      gallery_controller.dart
      gallery_screen.dart
      format_filter_row.dart
      camera_file_tile.dart
    import_queue/
      import_queue_controller.dart
      import_queue_screen.dart
  platform/
    camera_network_platform.dart
android/
  app/src/main/AndroidManifest.xml
  app/src/main/kotlin/com/example/sony_camera/CameraNetworkPlugin.kt
  app/src/main/kotlin/com/example/sony_camera/TransferForegroundService.kt
  app/src/main/kotlin/com/example/sony_camera/MainActivity.kt
ios/
  Runner/CameraNetworkPlugin.swift
  Runner/BackgroundTransferDelegate.swift
  Runner.xcodeproj/project.pbxproj
  Runner/Info.plist
macos/
  Runner/DebugProfile.entitlements
  Runner/Release.entitlements
windows/
  runner/camera_network_plugin.cpp
docs/research/reference-apps.md
docs/research/camera-capability-matrix.md
```

The initial Android feature should keep the protocol adapter, queue, and gallery separate. Later iOS and desktop work can add platform implementations without putting model-specific branches in widgets.

## Phase 0 — REA readiness and protocol evidence

### Task 1: Activate the configured REA analysis tools

**Files:**
- Read: `/Users/heleyang/.codex/config.toml`
- Read: `/Users/heleyang/.local/share/rea/android/jadx-headless-mcp-0.7.1-all.jar`
- Read: `/Users/heleyang/.local/share/rea/android/apktool`
- Read: `/Users/heleyang/.local/share/rea/android/apktool_3.0.3.jar`

- [ ] Restart Codex so the REA MCP server receives `REA_JADX_MCP_JAR`, `REA_APKTOOL_COMMAND`, and the Node 24.22.2 executable from the updated configuration.
- [ ] Call REA's `inspect_android_package` on the Imaging Edge Mobile base APK and require package/version/manifest extraction to complete.
- [ ] Call REA's `inspect_apktool_client` and require the selected launcher to be `/Users/heleyang/.local/share/rea/android/apktool` with version 3.0.3.
- [ ] If either provider reports unavailable, stop APK code analysis and report the exact missing provider; do not repeat the unchanged failing call.

### Task 2: Inspect the three reference packages without installing them

**Files:**
- Read: `/private/tmp/sony-camera-apks/imaging-edge-mobile.xapk`
- Read: `/private/tmp/sony-camera-apks/creators-app.xapk`
- Read: `/private/tmp/sony-camera-apks/monitor-plus.xapk`
- Create: `docs/research/reference-apps.md`

- [ ] Run `inspect_android_package` and `decode_android_resources` on each extracted base APK.
- [ ] Record package name, version, min/target SDK, permissions, activities, services, receivers, and exported components for each package in `docs/research/reference-apps.md`.
- [ ] Run `inspect_apk_signature` on each base APK. Record the APK SHA-256 and declared certificate fingerprints; explicitly label them unverified because the current REA operation does not perform cryptographic signature validation.
- [ ] Do not install or execute any APK and do not connect a phone or camera for this task.

### Task 3: Trace gallery, network, and import behavior in the reference apps

**Files:**
- Modify: `docs/research/reference-apps.md`
- Create: `docs/research/camera-capability-matrix.md`

- [ ] Use REA `search_android_classes` and `search_strings` on IEM 7.8.6 for Wi-Fi discovery, camera HTTP endpoints, media listing, thumbnail retrieval, original-file download, transfer queues, and retry/reconnect behavior.
- [ ] Use `inspect_android_class` and `inspect_android_method` only on classes/methods returned by those searches; retain REA Evidence IDs next to each finding.
- [ ] Repeat the same evidence-led workflow for Creators' App 3.6.0 and Monitor+ 1.6.0; do not treat filenames or UI labels alone as proof of a protocol behavior.
- [ ] Record per-app connection flow, gallery request flow, thumbnail path, original download path, retry strategy, background behavior, and any feature gating in `docs/research/reference-apps.md`.
- [ ] Create rows in `docs/research/camera-capability-matrix.md` for ZV-E10 first generation, other documented remote-command models, and unknown models. Each row must distinguish command control, wireless file listing, thumbnails, original download, USB transfer, and live view as supported / unsupported / unverified.

### Task 4: Decide the first ZV-E10 transfer adapter from evidence

**Files:**
- Modify: `docs/research/camera-capability-matrix.md`
- Read: `docs/superpowers/specs/2026-11-10-sony-camera-transfer-design.md`

- [ ] Compare REA findings with Sony's documented Camera Remote Command API and the official model support tables.
- [ ] Select the first adapter path only when the evidence identifies the file-list and original-download endpoints separately from remote-control commands.
- [ ] List unresolved facts as `unverified`; do not use the remote-command model list to imply photo-transfer support.
- [ ] Set an explicit validation checklist for a later physical ZV-E10 session: discover/connect, list files, retrieve one thumbnail, download one JPEG, download one RAW, compare byte sizes and hashes, background/foreground, Wi-Fi loss/recovery.

## Phase 1 — Android + ZV-E10 photo transfer MVP

### Task 5: Create the four-platform Flutter project shell

**Files:**
- Create: `pubspec.yaml`
- Create: `lib/main.dart`
- Create: `lib/app/camera_transfer_app.dart`
- Create: `lib/app/app_theme.dart`
- Create: platform runner files generated by Flutter under `android/`, `ios/`, `macos/`, and `windows/`

- [x] In the worktree root, run `flutter create --org com.example --project-name sony_camera --platforms=android,ios,macos,windows .`.
- [x] Verify the generated Kotlin package is `com.example.sony_camera`; use that exact package path for the Android files in later tasks. Replace the development application ID with a product-owned ID before any store release.
- [x] Keep `lib/main.dart` limited to `runApp(const CameraTransferApp())`.
- [x] Define `CameraTransferApp` as a `MaterialApp` with a dark photographic theme, Material 3 components, and a responsive content width.
- [x] Add a startup route that displays the connection screen and no network activity until the user selects Connect.
- [x] In this shell task, leave camera transport unconfigured on all targets. Implement Android Wi-Fi routing and the ZV-E10 protocol only in Tasks 9–10, after Phase 0 confirms the endpoints; do not guess a camera protocol here. Keep iOS/macOS/Windows explicitly marked “camera connection not yet configured.”

### Task 6: Define shared camera and transfer models

**Files:**
- Create: `lib/domain/models/camera_capabilities.dart`
- Create: `lib/domain/models/camera_file.dart`
- Create: `lib/domain/models/camera_page.dart`
- Create: `lib/domain/models/camera_profile.dart`
- Create: `lib/domain/models/transfer_job.dart`
- Create: `lib/domain/models/transfer_progress.dart`

- [x] Add `CameraCapabilities` with booleans for `canListFiles`, `hasThumbnails`, `canDownloadOriginals`, `canRemoteControl`, and `hasLiveView`.
- [x] Add `CameraFile` with `id`, `name`, `extension`, `format`, `byteLength`, optional `capturedAt`, optional `duration`, and optional `thumbnailKey`.
- [x] Define `CameraFileFormat` in `camera_file.dart` with values `raw`, `jpeg`, `mp4`, `avchd`, and `other`; map file extensions case-insensitively in `fromFileName`.
- [x] Add `CameraProfile` with `id`, `displayName`, optional `model`, optional `firmware`, `ConnectionKind connectionKind`, and locally stored connection configuration.
- [x] Define `ConnectionKind` with `cameraAccessPoint`, `sharedWifi`, and `usb` values.
- [x] Add `TransferJob` with `id`, `cameraFileId`, `destinationPath`, `state`, `bytesTransferred`, `totalBytes`, `attemptCount`, and optional `lastError`.
- [x] Define transfer states exactly as `queued`, `connecting`, `copying`, `interrupted`, `completed`, `cancelled`, and `failed`.
- [x] Add `TransferProgress` with `bytesTransferred` and nullable `totalBytes` fields.
- [x] Add `CameraPage<T>` with `items` and nullable `nextCursor` fields.
- [x] Add `NetworkConnectionResult` with `connected`, `requiresUserAction`, and nullable `message` fields.
- [x] Implement `CameraFileFormat.fromFileName(String name)` to map `.ARW` to `raw`, `.JPG`/`.JPEG` to `jpeg`, `.MP4` to `mp4`, `.MTS`/`.M2TS` to `avchd`, and preserve `other` for formats not yet mapped.

### Task 7: Define the capability-based adapter boundary

**Files:**
- Create: `lib/domain/ports/camera_adapter.dart`
- Create: `lib/domain/ports/camera_network.dart`
- Create: `lib/domain/ports/camera_http_transport.dart`
- Create: `lib/domain/ports/camera_credential_store.dart`
- Create: `lib/domain/ports/import_destination.dart`

- [x] Define the `CameraAdapter` contract with `Future<CameraProfile> connect(CameraProfile profile)`, `Future<CameraCapabilities> discoverCapabilities()`, `Future<CameraPage<CameraFile>> listFiles({String? cursor})`, `Future<Uint8List?> loadThumbnail(String fileId)`, and `Stream<TransferProgress> downloadOriginal(String fileId, String destinationPath)`.
- [x] Inject a `CameraHttpTransport` into each protocol adapter. Use `dart:io HttpClient` over the selected Android process network in the Android MVP; do not let widgets construct HTTP requests.
- [x] Import `dart:typed_data` for `Uint8List`; keep thumbnail images within 512 pixels on the longest edge and never load original media into this API.
- [x] Define `CameraNetwork` with `Future<NetworkConnectionResult> joinCameraNetwork(CameraProfile profile)`, `Future<bool> isCameraReachable(CameraProfile profile)`, and `Future<void> releaseCameraNetwork()`.
- [x] Define `CameraCredentialStore` with `Future<void> saveSecret(String profileId, String secret)`, `Future<String?> readSecret(String profileId)`, and `Future<void> deleteSecret(String profileId)`; use Android Keystore and iOS Keychain for saved Wi-Fi credentials.
- [x] Define `CameraHttpTransport` with `Future<String> getText(Uri uri)`, `Future<String> postJson(Uri uri, Map<String, Object?> body)`, `Future<Uint8List> getBytes(Uri uri)`, and `Stream<TransferProgress> downloadToFile(Uri uri, String temporaryPath)`.
- [x] Define `ImportDestination` with `Future<String> createTemporaryFile(CameraFile file)`, `Future<void> publishCompletedFile(String temporaryPath, CameraFile file)`, and `Future<void> discardTemporaryFile(String temporaryPath)`.
- [x] Keep protocol-specific request names, JSON payloads, and socket details out of these interfaces.

### Task 8: Build the B gallery and direct format filters against a local fixture

**Files:**
- Create: `lib/features/gallery/gallery_controller.dart`
- Create: `lib/features/gallery/gallery_screen.dart`
- Create: `lib/features/gallery/format_filter_row.dart`
- Create: `lib/features/gallery/camera_file_tile.dart`
- Create: `lib/data/adapters/fixture_camera_adapter.dart`
- Modify: `lib/app/camera_transfer_app.dart` (add the explicitly labeled local preview entry point)

- [x] Create a local fixture containing six RAW files, fourteen JPEG files, and four MP4 files with deterministic filenames and thumbnail placeholders.
- [x] Render a two-column large-preview gallery on mobile and an adaptive wider grid on desktop.
- [x] Generate the filter chips from formats present in the fixture; show “全部” first and show counts for each format.
- [x] Omit formats with no files and map unsupported extensions to a visible “其他” filter.
- [x] Make the current format filter update the visible list without clearing selected files of other formats unless the user explicitly selects a new subset.
- [x] Keep the selected file count and import action visible at the bottom of the screen.

### Task 9: Implement ZV-E10 connection and file listing adapter

**Files:**
- Create: `lib/data/adapters/sony_zve10_adapter.dart`
- Create: `lib/features/connection/connection_controller.dart`
- Create: `lib/features/connection/connect_screen.dart`
- Modify: `docs/research/camera-capability-matrix.md`

- [ ] Implement only the endpoints confirmed in Phase 0 for ZV-E10 first generation. Preserve the exact request/response evidence in `docs/research/reference-apps.md`.
- [ ] Parse the confirmed camera response into `CameraProfile`, `CameraCapabilities`, and `CameraFile` without model-specific logic in the gallery widgets.
- [ ] Fetch the first page of file metadata before thumbnails, and expose pagination through the adapter cursor.
- [ ] Report connection stages and recoverable errors using the shared controller state.
- [ ] If Phase 0 finds no usable original-file transfer path, stop before implementing a guessed endpoint and update the capability matrix with the blocked capability.

### Task 10: Add Android Wi-Fi routing and local file publishing

**Files:**
- Create: `lib/platform/camera_network_platform.dart`
- Create: `android/app/src/main/kotlin/com/example/sony_camera/CameraNetworkPlugin.kt`
- Create: `android/app/src/main/kotlin/com/example/sony_camera/TransferForegroundService.kt`
- Modify: `android/app/src/main/kotlin/com/example/sony_camera/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] Implement the Android plugin methods required by `CameraNetwork`; ask Android to join the selected camera network and report the resulting route rather than silently changing networks.
- [ ] Use `ConnectivityManager.requestNetwork` to obtain the camera network, then bind the app process with `ConnectivityManager.bindProcessToNetwork` for the active camera session; restore the previous binding on disconnect and show when internet access is unavailable through that route.
- [ ] Keep Wi-Fi credentials in app-private storage and never log them.
- [ ] Add only the local-network, Wi-Fi, notification, and connected-device service declarations required by the implemented flow.
- [ ] Start a foreground service only for a user-started active transfer; publish current job and progress in its notification and stop the service when the queue becomes idle.
- [ ] Route camera HTTP traffic through the selected camera network while keeping local file writes in the app's private or MediaStore destination.
- [ ] Surface OS permission denial and network switching in the connection screen with a user-readable recovery action.

### Task 11: Add durable original-file import queue

**Files:**
- Create: `lib/features/import_queue/import_queue_controller.dart`
- Create: `lib/features/import_queue/import_queue_screen.dart`
- Create: `lib/data/persistence/transfer_queue_store.dart`
- Create: `lib/data/persistence/thumbnail_cache.dart`
- Modify: `lib/domain/models/transfer_job.dart`

- [ ] Persist queue jobs and camera file metadata in an app-private JSON store using write-to-temp then atomic rename.
- [ ] Store each incoming file to a temporary path and publish it only after the adapter reports completion and the received byte length matches camera metadata when available.
- [ ] Persist state and byte progress after each bounded transfer chunk; mark transient network failures `interrupted` and present Retry and Cancel actions.
- [ ] Resume at a byte offset only when the Phase 0 protocol evidence confirms range support; otherwise restart the single interrupted file.
- [ ] Preserve camera filenames and resolve collisions by appending ` (2)`, ` (3)`, and so on before the extension.
- [ ] Render queue state, bytes copied, total bytes, and per-file retry status.

### Task 12: Validate the Android MVP on the physical ZV-E10

**Files:**
- Modify: `docs/research/camera-capability-matrix.md`
- Modify: `docs/research/reference-apps.md`

- [ ] Connect Android to the first-generation ZV-E10 using the confirmed Phase 0 path.
- [ ] Check discovery, saved profile reconnect, full file listing, dynamic RAW/JPEG/MP4 filters, and first thumbnail latency.
- [ ] Import one JPEG, one RAW, and one MP4; compare source and destination lengths and compute SHA-256 to confirm byte-for-byte integrity.
- [ ] Background and foreground the app during an import, turn camera Wi-Fi off and back on, and relaunch the app to confirm completed jobs remain complete and interrupted jobs can resume.
- [ ] Record the results and actual per-file transfer rates; do not claim a performance improvement until compared with IEM under the same camera, file set, radio conditions, and device.

## Phase 2 — iOS platform integration

### Task 13: Implement iOS local-network permission and camera-network handling

**Files:**
- Create: `ios/Runner/CameraNetworkPlugin.swift`
- Create: `ios/Runner/BackgroundTransferDelegate.swift`
- Modify: `ios/Runner/Info.plist`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

- [ ] Add `NSLocalNetworkUsageDescription` with a plain-language explanation that the app uses the local network to connect to a Sony camera and transfer selected files.
- [ ] Implement the native iOS side of `CameraNetwork` and surface permission/network-selection states through the same Dart interface as Android.
- [ ] Use the background URLSession path only for eligible HTTP(S) camera downloads; persist its session identifier and associate task completion with the matching `TransferJob`.
- [ ] For unsupported protocols or unavailable camera routes, keep the queue durable and resume it when the app returns to the foreground.
- [ ] Request Photos or Files access only when the user chooses that destination; keep local private import as the fallback.

### Task 14: Validate iOS transfer and lifecycle behavior

**Files:**
- Modify: `docs/research/camera-capability-matrix.md`

- [ ] Build and run on a physical iPhone using the Mac/Xcode toolchain.
- [ ] Confirm local-network permission, camera discovery, gallery, original file import, and format filters.
- [ ] Confirm eligible URLSession transfers continue under system suspension and that force-quit behavior is accurately shown to the user.
- [ ] Confirm other active queue items resume on foreground re-entry after a camera-route interruption.
- [ ] Record the exact supported background behavior; do not describe it as guaranteed uninterrupted Wi-Fi.

## Phase 3 — macOS and Windows platform integration

### Task 15: Add desktop layout and folder destination

**Files:**
- Modify: `lib/features/gallery/gallery_screen.dart`
- Modify: `lib/features/gallery/camera_file_tile.dart`
- Create: `lib/features/import_queue/desktop_folder_destination.dart`
- Modify: `macos/Runner/DebugProfile.entitlements`
- Modify: `macos/Runner/Release.entitlements`

- [ ] Use a resizable multi-column gallery and desktop side panel while preserving the same `CameraFile`, format filter, and selection states.
- [ ] Add mouse selection, keyboard focus, and drag/scroll behavior for the gallery without changing mobile layout behavior.
- [ ] Use a system folder picker and persist the user's selected destination.
- [ ] Add macOS local-network usage text and required entitlements for the implemented connection path.
- [ ] Preserve per-file temporary writes, collision handling, and restart recovery in the selected desktop folder.

### Task 16: Add Windows local-network support and package target

**Files:**
- Create: `windows/runner/camera_network_plugin.cpp`
- Modify: `windows/runner/CMakeLists.txt`
- Modify: `windows/runner/Runner.rc`
- Modify: `docs/research/camera-capability-matrix.md`

- [ ] Implement the Windows side of the same `CameraNetwork` and download streaming interfaces.
- [ ] Keep route and network errors visible while preserving a normal internet connection where Windows routing permits it.
- [ ] Add the Windows folder picker, restart recovery, and file collision behavior.
- [ ] Build and run the Windows target on the user's Windows machine; record OS version, architecture, connection time, first-thumbnail time, and measured file throughput.
- [ ] Confirm macOS and Windows feature support individually before publishing the shared platform matrix.

Remote controls and live view are outside this plan. After the photo-transfer releases, prepare a separate product design and implementation plan for those capabilities.

## Delivery checks

- Compile each target only after its task is implemented; Windows packaging must run on Windows, and iOS packaging must run on macOS with Xcode.
- Verify all four platforms' local-network privacy prompts and data destinations before publishing.
- Use the approved design in `docs/superpowers/specs/2026-11-10-sony-camera-transfer-design.md` as the source of truth for scope.
- Do not claim universal compatibility, persistent iOS Wi-Fi, or faster transfer without the corresponding recorded device evidence.
- Do not add or run automated tests unless the user explicitly asks for testing or implementation verification.
