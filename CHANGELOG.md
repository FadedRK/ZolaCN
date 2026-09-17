# Changelog

## [1.0.1] — 2026-09-17

### Changed
- Reorganized the dylib source into dedicated Localization and Recall modules.
- Replaced the monolithic runtime implementation with `Tweak.xm` as the module entry point.
- Updated the README and project architecture documentation.
- Kept the standalone `ZolaCN.dylib` build and GitHub Actions workflow.

### Compatibility
- Target bundle identifier: `vn.com.vng.zingalo`
- Architectures: `arm64`, `arm64e`
- Minimum deployment target used for the build: iOS 15.0

## [1.0.0] — 2026-09-09

First public release.

### Added
- Standalone `ZolaCN.dylib` for TrollStore + TrollFools.
- Runtime Chinese localization for Zalo iOS.
- Translation table embedded directly into the dylib for reliable runtime loading.
- Vietnamese/English source text translation with UIKit fallbacks.
- GitHub Actions build that produces the standalone dylib artifact.
