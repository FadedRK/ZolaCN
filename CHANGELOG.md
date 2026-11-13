# Changelog

## [1.0.6] — 2026-11-14

### Fixed
- Defer native AAC replacement until the original Zalo recording gesture has ended and the file size is stable, avoiding writes while the recorder is still creating the file.
- Keep AudioItem metadata association separate from file replacement so model initialization does not overwrite an active recorder file.
- Add a 90-second pending-send expiry and clear the pending state after a cancelled or failed native recording gesture.
- Remove the dedicated VoiceTrace runtime module from the release build; the release focuses on the voice-pack sending path rather than diagnostic tracing.


## [1.0.5] — 2026-11-13

### Added
- Corrected the VoiceBoardViewModel upload failure callback to the runtime-confirmed selector `uploader:sessionConfiguration:didStopWithError:`.
- Added exact-encoding probes for upload chunk preparation and completion callbacks.
- Kept upload success callback and UploadedVoiceLink field inspection.
- Uses a separate `ZolaVoiceTrace-v7.1.log` file with local-time timestamps.

### Safety
- All three added probes require exact runtime type-encoding matches.
- Broad uploader lifecycle swizzling remains disabled.
- Swift instance ivar values are never read.
- Voice-pack send path and UI remain unchanged.

## [1.0.4] — 2026-11-13

### Added
- V7 targeted tracing for VoiceBoardViewModel and upload completion/failure callbacks.
- Exact Objective-C type-encoding validation before callback instrumentation.
- UploadedVoiceLink getter inspection for fileId, aacLink, and originalLink when a validated completion callback fires.
- Local-time timestamps in the voice trace log.

### Safety
- Kept Swift object introspection metadata-only; no instance ivar values are read.
- Kept broad uploader lifecycle swizzling disabled.
- Preserved the existing voice-pack send path and UI.

## [1.0.1] — 2026-10-01

Final integrated release.

### Added
- Chinese runtime localization for Zalo.
- Anti-recall support for self-recall display control.
- Integrated **Themes & Interface** settings.
- Custom chat bubbles and chat background.
- Global chat background switch.
- Transparent top bar.
- Fully transparent bottom bar and native chat input editor.
- Chinese, Vietnamese, and English interface options.
- Debian package and SHA-256 release checksums.

### Fixed
- Restored the original anti-recall settings entry inside ZolaCN.
- Reduced the Zalo Settings integration to a single **zola** entry.
- Restored the complete theme settings from the original theme module.
- Added proper close, edge-swipe, and sheet dismissal behavior for plugin settings.
- Removed duplicate anti-recall installation paths.
- Modules no longer use the Zalo version list as a global installation gate.

### Compatibility
- Target bundle identifier: `vn.com.vng.zingalo`
- Compatibility reference versions: `26.09.01`, `26.08.02`, `26.08.01`, `26.07.01.1`, `26.07.01`, `26.06.02.1`
- Architectures: `arm64`, `arm64e`
- Minimum deployment target: iOS 15.0

### Release assets
- `ZolaCN.dylib`
- `com.fadedrk.zolacn_1.0.1_iphoneos-arm64.deb`
- `SHA256SUMS.txt`

## [1.0.0] — 2026-09-09

First public release.
