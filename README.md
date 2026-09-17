# ZolaCN

ZolaCN is a standalone iOS dynamic library for Zalo that provides Chinese runtime localization and anti-recall support.

## Current Release — v1.0.0

**Stable public release**

The release artifact is **`ZolaCN.dylib`**. It is designed for use with **TrollStore + TrollFools** and targets Zalo's bundle identifier:

```text
vn.com.vng.zingalo
```

## Features

### Chinese Localization

- Runtime translation of Zalo UI text from Vietnamese/English to Chinese.
- Translation table embedded directly into the dylib.
- UIKit fallback hooks for labels, buttons, navigation items, tab items, search placeholders, and text-field placeholders.
- Supports `arm64` and `arm64e`.

### Anti-Recall

- Preserves the original message content when a recall event is processed and the original text is available.
- Stores previously seen message text locally so it can be restored when Zalo replaces the content with a recall notice.
- Displays the original message together with a recall indicator instead of only showing Zalo's default recall text.
- Supports Chinese, English, and Vietnamese recall indicators.
- Can be enabled/disabled through the runtime preference `ZolaAntiRecallEnabled`.
- The anti-recall logic is implemented in `dylib/ZolaAntiRecall.m`.

## Install

1. Download **`ZolaCN.dylib`** from the [v1.0.0 Release](https://github.com/FadedRK/ZolaCN/releases/tag/v1.0.0).
2. Open TrollFools and select Zalo.
3. Inject `ZolaCN.dylib`.
4. Completely terminate Zalo and launch it again.

The translation and anti-recall features work at runtime, so the original Zalo resources do not need to be replaced.

## Build

The repository does not require a local Theos installation. GitHub Actions builds the standalone dylib automatically.

The build process generates the embedded translation source from `Translations.plist` and outputs:

```text
ZolaCN.dylib
```

## Project layout

```text
ZolaCN/
├── .github/workflows/build-dylib.yml   # CI build + release publishing
├── .gitattributes                      # GitHub language classification
├── dylib/
│   ├── Makefile
│   ├── TweakRaw.xm                     # runtime localization implementation
│   ├── ZolaAntiRecall.m                # anti-recall implementation
│   ├── ZolaCN.plist                    # target bundle filter
│   └── build_embed.py                  # embeds translation table
├── Translations.plist                  # translation source table
├── VERSION                             # current release version
└── CHANGELOG.md
```

## Notes

v1.0.0 is the current stable public release. Translation coverage depends on the bundled table and the UI paths used by the current Zalo build. Anti-recall behavior depends on Zalo's internal message model and recall processing path; dynamically generated or unsupported message types may require additional hooks in future releases.
