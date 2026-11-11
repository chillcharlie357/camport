# Camera transfer runtime implementation plan

**Goal:** Connect to Sony media-transfer mode, browse metadata and thumbnails, import original files through a durable queue, persist bounded thumbnail cache, and handle platform background/foreground transitions.

**Architecture:** SSDP + Sony DigitalImaging device descriptions identify camera/media capabilities. PTP/IP command/event channels implement bounded streaming and Sony's contents-transfer handshake. Shared Dart services own profiles, pagination, cache and queue; native platforms own network routing/background leases. Preserve the approved UI and connect its actual actions.

## Implementation tasks

- [ ] Implement PTP/IP framing, handshake, serialized transactions, bounded data and file streaming; verify with local TCP camera fixtures, fragmented packets, malformed frames, timeouts and disconnects.
- [ ] Implement Sony SSDP/device XML parsing and LAN-only endpoint validation; add manual host fallback. Use SDIO_OpenSession/Connect and contents-transfer mode before listing actual card storage. Record exact static protocol evidence; capability-gate unsupported operations.
- [ ] Implement metadata pagination, GetThumb without original fallback, and chunked original transfer with offsets and source-identity validation. Never issue capture/delete/settings changes as part of browsing/import.
- [ ] Add atomic, bounded disk LRU cache with camera/storage/file version keys; integrate into the existing viewport scheduler, cache clear and app restart behavior.
- [ ] Add persistent queue, safe destination filenames, .part recovery, length checks/local SHA-256, collision protection, pause/retry/cancel and process-restart recovery.
- [ ] Add Android foreground-service/network routing/engine retention; iOS background time-budget checkpoint and foreground resume for PTP; macOS/Windows sleep inhibition while transferring. Do not promise unlimited iOS PTP background execution.
- [ ] Wire real connection, gallery pagination, original import destination, queue/status actions and saved-profile recovery into the app. Keep sample mode explicitly separate.
- [ ] Run focused protocol/disk/queue/lifecycle/widget tests, analysis and all-platform CI; submit reviewable changes. No physical phone/camera connection or third-party APK execution without a change to the earlier user instruction.

## Evidence and scope

IEM base APK SHA-256 remains recorded in `docs/research/android-protocol-evidence.md`. Targeted static files in `/private/tmp/sony-static-protocol/runtime-focus` identify Connect `[phase,0,0]`, SDIO_OpenSession `[1,mode]`, and GetPartialLargeObject `0x9211` with `[handle,offsetLow,offsetHigh,count]`; `0x9219` is a distinct short-video operation and is not substituted for original transfer.

The public [ZV-E10 protocol investigation](https://github.com/peiyuanix/zv-e10-creators-app-patcher/blob/master/docs/en/01-how-it-works.md) reports Smartphone Connect exposing card media, unlike PC Remote mode. This guides implementation and fixture cases; it is not our app's own hardware acceptance. Actual firmware/radio/background speed remains a separate device-validation gate.
