# Changelog

## [1.0.1] — 2026-10-01

Theme integration and release packaging update.

### Added
- Ported the stable fully transparent bottom input implementation into ZolaCN.
- The native chat editor path is made transparent without hooking background-color setters.
- Added top-bar transparency support and hardened lazy-loaded private-class hooks.
- Added centralized Zalo runtime-version compatibility checking.
- Added Debian packaging alongside the standalone dylib release.
- Added release SHA-256 checksums.

### Fixed
- Separated anti-recall runtime logic from the localization source file.
- Removed the duplicate anti-recall implementation that could install the same runtime hook twice.
- Unified anti-recall language selection with the main interface-language preference.
- Prevented unsupported Zalo builds from installing runtime hooks.

### Compatibility
- Target bundle identifier: `vn.com.vng.zingalo`
- Supported Zalo versions: `26.09.01`, `26.08.02`, `26.08.01`, `26.07.01.1`, `26.07.01`, `26.06.02.1`
- Architectures: `arm64`, `arm64e`
- Minimum deployment target: iOS 15.0

### Release assets
- `ZolaCN.dylib` — standalone dynamic library for TrollStore/TrollFools.
- `com.fadedrk.zolacn_1.0.1_iphoneos-arm64.deb` — Debian package for jailbreak package managers.
- `SHA256SUMS.txt` — checksums for release files.

## [1.0.0] — 2026-09-09

First public release.

### Added
- Standalone `ZolaCN.dylib` for TrollStore + TrollFools.
- Runtime Chinese localization for Zalo iOS.
- Translation table embedded directly into the dylib for reliable runtime loading.
- Vietnamese/English source text translation with UIKit fallbacks.
- GitHub Actions build that produces the standalone dylib artifact.

### Compatibility
- Target bundle identifier: `vn.com.vng.zingalo`
- Architectures: `arm64`, `arm64e`
- Minimum deployment target used for the build: iOS 15.0

### Notes
- This release is dylib-only. No Debian package is required.
- The current release has been verified on the user's Zalo installation with TrollFools injection.
- The translation coverage depends on the bundled table and the UI paths used by the current Zalo build.
