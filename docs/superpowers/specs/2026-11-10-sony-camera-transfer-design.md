# CamPort — Sony Camera Photo Transfer Product and Technical Design

**Status:** Scope approved; implementation in progress  
**Date:** 2026-11-10

**Acceptance source of truth:** [Requirements and acceptance criteria](../../requirements/sony-camera-requirements-and-acceptance.md). Latest decisions: same-name RAW/JPG/PNG merging, unified local ratings, filters under More, and preview-first loading with no automatic original-file prefetch.  
**Platforms:** iOS, Android, macOS, Windows  
**Primary device for validation:** Sony ZV-E10 (first generation)

## 1. Product goal

Build a cross-platform Sony camera companion whose first release makes it quick to connect to a camera, browse its files, preview them, and import original photos and videos. Mobile is the first priority. The initial compatibility target is the user's first-generation ZV-E10; the architecture must allow additional models and transfer methods to be added through capability-aware adapters.

The product addresses the user's reported problems with Imaging Edge Mobile and Monitor+: slow or unreliable connection, slow gallery previews, slow transfer, and sessions that do not recover well after the app is backgrounded. The first release is the photo-transfer foundation of a broader replacement. Live monitoring and remote shooting are later capabilities, not first-release requirements.

## 2. Users and platforms

- iOS and Android: connect to the camera, browse, preview, select, import, and follow transfer progress. Android is the first implementation target because the user has an Android device.
- macOS and Windows: share the same gallery, selection, and transfer model with a responsive desktop layout, keyboard/mouse support, and a destination-folder workflow.
- The product should not claim universal Sony camera support. Each camera reports a capability set discovered from model/firmware and protocol probes; unsupported actions remain hidden or clearly unavailable.

## 3. Evidence and assumptions

- The user owns a first-generation ZV-E10, an Android device, a Mac, and a Windows computer. No phone is connected for this research step.
- Sony lists the ZV-E10 in its Camera Remote Command API model table. That establishes a remote-command path for the model, not that every photo-browsing or full-resolution transfer operation is available through that API. File access must be confirmed separately through static analysis and a later camera validation session. [Sony Camera Remote Command API](https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html?id=portal)
- Sony's current Creators' App compatibility page does not list the first-generation ZV-E10, which matches the user's stated compatibility gap. [Creators' App compatibility](https://creatorscloud.sony.net/catalog/en-rs/creatorsapp/index.html)
- The user selected the large-preview gallery layout (B) and direct per-format filters such as RAW, JPEG, and MP4.
- The downloaded reference packages are Imaging Edge Mobile 7.8.6, Creators' App 3.6.0, and Monitor+ 1.6.0. REA has parsed their declared signing records, but cryptographic signature verification was not performed. Full Android manifest/code inspection remains pending because Codex must restart to load the newly configured JADX and Apktool providers.
- The product will learn protocol behavior from the reference apps and camera-compatible APIs, but will not copy proprietary source code, assets, or branding.

## 4. First-release scope

### Included

1. Discover/connect to a remembered or newly configured Sony camera over Wi-Fi.
2. Show camera identity, connection state, and available media/card information when the camera exposes it.
3. Browse camera files with lazy thumbnail loading and a fast placeholder-first list.
4. Filter directly by file format present on the camera, with per-format counts. Initial examples: RAW (for example ARW), JPEG, MP4, and any other formats proven for the connected model. Do not show an empty format filter.
5. Open a large preview and inspect basic file metadata.
6. Select one or more files and import their original bytes to the device. Do not silently downsize, transcode, or upload to a cloud service. Explicit photo ratings may update rating metadata in local and camera original files, while preserving image data.
7. Maintain a durable transfer queue with per-file progress, cancel/retry, collision handling, and recovery after transient connection loss or app restart.
8. Store camera profiles and last-used import locations locally.

### Later releases

- Additional Sony models and alternate protocols after they are individually validated.
- USB/MTP/PTP import where the camera and host platform expose the needed interfaces.
- Remote shutter/settings and live-view monitoring, after the photo-transfer flow is reliable and the relevant camera APIs are understood.
- Desktop features such as batch organization and user-configurable file naming.

### Explicitly out of scope for the first release

- Cloud accounts, cloud upload, social sharing, camera firmware updates, and proprietary service features unrelated to direct file transfer.
- A promise that every Sony camera, firmware, phone, or operating-system version works identically.
- Circumventing Monitor+ purchase or activation checks. The app can implement its own compatible features where the camera protocol permits.

## 5. Product experience

### Connection

- A single “Connect camera” entry point scans for known camera profiles and offers an explicit manual setup path when discovery is unavailable.
- Explain the required local-network permission at the point of use. Keep the selected camera and last successful connection details on-device.
- Report distinct states: discovering, joining camera network, connecting, ready, interrupted, and reconnecting. Show a concrete next action for recoverable errors.
- Probe capabilities after connection instead of assuming that camera model name alone guarantees a feature.

### Gallery

- Use the selected B layout: large two-column previews on mobile, with a responsive multi-column grid on desktop.
- Show filename, file type, and video duration where available. Load thumbnails before full-resolution previews; cache them locally and request originals only when the user opens or imports a file.
- Place file-format filters and the same-name merge switch inside the top-right More → 筛选与显示 panel. Offer actual formats on the card, including RAW, JPEG, PNG, and MP4 where present. Keep only a brief active-condition summary on the page.
- Merge same-basename RAW with JPG/JPEG/PNG when enabled. A shared 0–5 desired photo rating survives split/merged views. The user permits writing rating metadata into both local originals and camera originals; track each target separately and verify writes before reporting success. Apply physical file-format filtering before grouping, preserving selected file IDs.
- Never load originals to populate the gallery. Fetch metadata first, then visible thumbnails plus at most the next row. Use cached thumbnails first; original-file loading requires an explicit user action. Wireless preview latency and request/byte budgets are P0 acceptance items.
- Selecting a format filters the current camera listing without triggering a fresh full listing request when the data is already cached.
- Selection count and an “导入” action remain visible while scrolling.

### Import queue

- Queue each file independently and write to a temporary destination before atomically renaming it on success; an incomplete transfer must not look like a complete photo.
- Preserve the camera filename and original file bytes by default. Resolve collisions with a clear choice or safe automatic suffix.
- Record enough transfer state to retry safely. Resume from a byte offset only when the camera protocol supports reliable range/resume semantics; otherwise restart that file and preserve completed files.
- On iOS and Android, save to an app-controlled location first, then offer the system photo library or file picker destination according to platform permissions. On desktop, use a chosen folder.

## 6. Technical architecture

### Recommended structure: Flutter UI plus platform adapters

Use one Flutter codebase for the application UI and shared product logic. Flutter officially supports Android, iOS, macOS, and Windows, and allows platform-specific code through native interop/plugin APIs. The chosen framework therefore covers all four requested platforms while retaining an escape hatch for OS-level Wi-Fi and background behavior. [Flutter platform support](https://docs.flutter.dev/reference/supported-platforms), [Flutter platform integration](https://docs.flutter.dev/platform-integration)

Separate the code into these boundaries:

1. **Presentation:** adaptive mobile and desktop views, gallery, preview, selection, queue, and connection status.
2. **Application services:** camera discovery flow, capability negotiation, gallery paging, thumbnail cache, and transfer queue orchestration.
3. **Camera protocol adapters:** a stable `CameraAdapter` interface with independently implemented connection, listing, thumbnail, file-download, and remote-control capabilities. Remote control and live view are optional interface capabilities, not requirements of every adapter.
4. **Platform services:** native Android/iOS Wi-Fi routing and permissions, lifecycle/background transfer hooks, local media-library access; macOS/Windows local-network permission and filesystem integration.
5. **Persistence:** local database for camera profiles, file metadata, cached thumbnails, queue state, and completed-import records. No server is required for the first release.

Keep transport and parsing in Dart until profiling or native APIs require a native implementation. Add Rust only if measured performance or a protocol library justifies the extra build and debugging burden.

### Protocol strategy

- Investigate the camera's supported Sony remote-command and media-transfer paths separately. Treat command/control and file browsing/download as different capabilities.
- Define adapters around observable features rather than model-name conditionals scattered through the UI.
- Start with the protocol proven to support the first-generation ZV-E10. Add an MTP/PTP adapter only after tests show it improves a needed platform/model combination.
- Store protocol-specific connection details locally and avoid transmitting them to a service.
- REA is a development research tool only; it is not bundled into the consumer app.

### Why not one generic “Sony protocol” implementation

Sony camera generations expose different combinations of remote commands, Wi-Fi transfer, USB modes, and media access. A capability handshake and adapter registry let the same gallery handle those differences without promising that a single command API covers them all.

## 7. Background and interruption handling

The app must preserve transfer intent and recover cleanly, but it must not promise that every OS will keep the camera Wi-Fi link active indefinitely.

- Persist queue state before starting each file. Detect loss of the camera route, mark the active item interrupted, and retry with bounded backoff when the camera becomes reachable again.
- Android may use a user-initiated foreground service with the connected-device service type for an active camera transfer, subject to platform permissions and policy. [Android foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- iOS background `URLSession` can continue eligible HTTP/HTTPS transfers outside the app process and restore their status when the app returns. A force-quit cancels these transfers, and a camera's local Wi-Fi route may still constrain availability. For protocols that cannot use background `URLSession`, resume the persisted queue when the app returns to the foreground. [Apple background downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background), [Apple background session behavior](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background%28withidentifier%3A%29)
- On desktop, let transfers continue while the app is open; persist queue state across a normal app exit and offer resume on next launch.

## 8. Delivery phases

### Phase 0 — protocol confirmation

- Restart Codex so REA loads the pinned Node 24.22.2, JADX 0.7.1, and Apktool 3.0.3 configuration.
- Analyze the three downloaded APKs with REA: manifest permissions, network/security configuration, package structure, media browsing, connection recovery, thumbnail loading, and transfer-related code paths.
- Compare those findings against Sony's documented interfaces and the existing SonyPhotoTransfer project.
- Build a capability matrix for first-generation ZV-E10 and identify which claims require a camera session.

### Phase 1 — Android + first-generation ZV-E10

- Build the connection flow, large-preview gallery, dynamic type filters, original-file import, and recoverable transfer queue.
- Use a small synthetic camera fixture for repeatable UI and queue behavior before connecting to the physical camera.
- After the protocol path is clear, validate connection, listing, previews, import integrity, app backgrounding, Wi-Fi loss, and reconnect against the user's camera.

### Phase 2 — iOS

- Reuse the gallery and queue logic; implement native local-network permission, network selection, and eligible background URLSession transfers.
- Validate behaviors on a physical iPhone before claiming background continuity.

### Phase 3 — macOS and Windows

- Reuse gallery, metadata, filtering, and transfer logic with a desktop layout and folder picker.
- Validate local-network permissions, Wi-Fi camera routing, and throughput independently on both operating systems.

## 9. Success measures

Record a baseline on the same camera, file set, access point conditions, and host device before optimization:

- Time from the user tapping Connect to the first usable gallery state.
- Time to first visible thumbnail and time to a scrollable first page.
- Median and p90 original-file throughput by file size and type.
- Percentage of imports that complete with verified byte length and no corruption.
- Recovery rate after background/foreground transitions, temporary Wi-Fi loss, and app relaunch.
- Number of user actions needed to reconnect to a remembered camera.

Compare against IEM under the same conditions. Set numeric targets after recording the baseline rather than selecting unsupported thresholds in advance.

## 10. Risks and unresolved facts

- **ZV-E10 file-transfer interface:** Sony documents remote-command support for the model, but this does not prove that an open media-download path exposes originals. Resolve with APK analysis and camera validation before locking the first adapter.
- **iOS local Wi-Fi lifecycle:** OS scheduling, camera AP behavior, and background transfer eligibility may limit continuous imports. Durable queue/reconnect is the guaranteed design behavior; uninterrupted transfer is conditional.
- **Camera preview protocol:** thumbnail availability and latency may depend on camera firmware or a proprietary endpoint. Keep preview loading asynchronous and cache results.
- **Desktop Wi-Fi behavior:** connecting a computer to the camera's AP can remove internet access or change routes. Make network status visible and test route selection on macOS and Windows.
- **Intel Mac support:** Flutter currently lists macOS x64 support while phasing it out. Confirm the user's Mac architecture and minimum macOS version before setting a desktop support promise. [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)
- **Reference-app analysis:** the current Codex REA process was started before its new engine settings. The updated configuration has been checked with Node 24.22.2 and the JAR release checksum, but REA needs a Codex restart before Android source/manifest analysis can run in its current MCP session.

## 11. Alternatives considered

### A. Flutter shared application — recommended

One UI and shared logic across all four platforms, with native adapters for Wi-Fi routing, permissions, background work, and file saving. It best matches the requested breadth and mobile-first priority. The main cost is maintaining a small amount of platform-specific integration code.

### B. Kotlin Multiplatform + Compose Multiplatform

Can share UI and logic across Android, iOS, macOS, and Windows while retaining access to native APIs. It is a credible alternative, especially for a Kotlin-centered team. The current Compose Multiplatform compatibility table lists macOS 13 arm64 for desktop, which may exclude Intel Macs; framework and toolchain coordination adds cost for this project. [Compose Multiplatform compatibility](https://kotlinlang.org/docs/multiplatform/compose-compatibility-and-versioning.html)

### C. Native iOS/Android apps plus separate desktop app

Offers the most direct platform-native implementation and customization, but duplicates gallery and transfer behavior across separate clients and slows feature parity. It is justified if the protocol later requires substantially different mobile implementations.

## 12. Decisions recorded

The user approved Flutter, the photo browsing/import first-release scope, and the v2 silver visual design. The approved visual baseline is saved in commit `6c4db3b`. The user subsequently requested simple same-name RAW/JPG/PNG merging and unified ratings, with filters in the top-right overflow menu. Preview loading speed is the primary performance concern, especially over Wi-Fi; browsing must not download the entire camera library. The linked requirements document defines measurable acceptance and current evidence limits.
