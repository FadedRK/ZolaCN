# ZolaCN

ZolaCN is a standalone iOS dynamic library for Zalo that provides Chinese runtime localization, anti-recall support, and theme customization.

## Current Release — v1.0.2

**Stable public release**

Release assets:
- **`ZolaCN.dylib`** — standalone build for TrollStore + TrollFools.
- **`com.fadedrk.zolacn_1.0.2_iphoneos-arm64.deb`** — Debian package for jailbreak package managers.
- **`SHA256SUMS.txt`** — release checksums.

Target bundle identifier:

```text
vn.com.vng.zingalo
```

## Zalo Compatibility

v1.0.2 enables runtime hooks only for the latest six Zalo App Store versions available when the release was prepared:

| Zalo version | Status |
| --- | --- |
| 26.09.01 | Supported |
| 26.08.02 | Supported |
| 26.08.01 | Supported |
| 26.07.01.1 | Supported |
| 26.07.01 | Supported |
| 26.06.02.1 | Supported |

This list is intentionally explicit. When Zalo publishes a newer build, update `dylib/ZolaCompatibility.m` and release a new ZolaCN version after testing.

The version list was checked against Zalo's App Store version history on 2026-10-01. The latest listed release is 26.09.01 (14 Sep 2026).

[Zalo on the App Store](https://apps.apple.com/vn/app/zalo/id579523206)

## Features

### Chinese Localization
- Runtime translation of Zalo UI text from Vietnamese/English to Chinese.
- Translation table embedded directly into the dylib.
- UIKit fallback hooks for labels, buttons, navigation items, tab items, search placeholders, and text-field placeholders.
- Supports `arm64` and `arm64e`.

### Anti-Recall
- Preserves previously seen message content when Zalo processes a recall.
- Handles both self-recall and other-party recall when the original text can be recovered.
- Falls back to Zalo's native recall behavior when the message cannot be safely reconstructed.
- Supports Chinese, English, and Vietnamese recall indicators.
- The anti-recall implementation lives in `dylib/ZolaAntiRecall.m`.

### Themes & Appearance
- Custom chat bubbles for both sides.
- Custom chat background.
- Global chat background switch.
- Transparent top bar.
- Fully transparent bottom bar and native chat input editor.
- The stable input path targets `KBChatInputComponentView → HPGrowingTextView → MyTextView → HPTextViewInternal`.
- Input transparency is applied to live instances during parent layout; no `setBackgroundColor:` hook is used.

## Install — dylib
1. Download **`ZolaCN.dylib`** from the v1.0.2 Release.
2. Open TrollFools and select Zalo.
3. Inject `ZolaCN.dylib`.
4. Completely terminate Zalo and launch it again.

## Install — deb
Install `com.fadedrk.zolacn_1.0.1_iphoneos-arm64.deb` through your jailbreak package manager. The package installs:
- `/Library/MobileSubstrate/DynamicLibraries/ZolaCN.dylib`
- `/Library/MobileSubstrate/DynamicLibraries/ZolaCN.plist`

## Build
GitHub Actions builds and publishes the release automatically when `VERSION` changes on `main`.

The build process:
1. Embeds `Translations.plist`.
2. Compiles `ZolaCN.dylib` for `arm64/arm64e`.
3. Builds the Debian package from the same dylib.
4. Generates SHA-256 checksums.
5. Publishes the dylib, deb, and checksum files to the GitHub Release.

## Project layout
```text
ZolaCN/
├── .github/workflows/build-release.yml
├── dylib/
│   ├── Makefile
│   ├── TweakRaw.xm              # runtime localization + settings entry
│   ├── ZolaAntiRecall.m         # anti-recall runtime
│   ├── ZolaTheme.m              # bubbles, background, transparency
│   ├── ZolaCompatibility.h/.m   # supported Zalo versions
│   ├── ZolaCN.plist             # target bundle filter
│   ├── build_embed.py           # embeds translation table
│   └── build_deb.py             # builds the Debian package
├── Translations.plist
├── VERSION
├── CHANGELOG.md
└── README.md
```

## Notes

Runtime behavior depends on Zalo's internal UIKit hierarchy and message-processing classes. v1.0.1 explicitly limits hook installation to the six referenced Zalo versions above; unsupported versions are left untouched.
