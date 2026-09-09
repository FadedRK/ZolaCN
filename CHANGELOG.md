# Changelog

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
