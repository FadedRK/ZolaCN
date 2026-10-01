# Changelog

## [1.0.1] — 2026-10-01

Final integrated release.

### Added
- Chinese runtime localization for Zalo.
- Anti-recall support with self-recall display control.
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
