# ZolaCN

ZolaCN is a standalone iOS dynamic library that adds Chinese runtime localization to Zalo.

## v1.0.0

First public release.

The release artifact is **`ZolaCN.dylib`**. It is designed for use with **TrollStore + TrollFools** and targets Zalo's bundle identifier:

```text
vn.com.vng.zingalo
```

## Features

- Runtime translation of Zalo UI text from Vietnamese/English to Chinese.
- Translation table embedded directly into the dylib.
- UIKit fallback hooks for labels, buttons, navigation items, tab items, search placeholders, and text-field placeholders.
- Supports `arm64` and `arm64e`.
- No Debian package is required.

## Install

1. Download `ZolaCN.dylib` from the GitHub Release.
2. Open TrollFools and select Zalo.
3. Inject `ZolaCN.dylib`.
4. Completely terminate Zalo and launch it again.

The translation works at runtime, so the original Zalo resources do not need to be replaced.

## Build

The repository does not require a local Theos installation. GitHub Actions builds the standalone dylib automatically.

The build process generates the embedded translation source from `Translations.plist` and outputs:

```text
ZolaCN.dylib
```

## Project layout

```text
ZolaCN/
├── .github/workflows/build-dylib.yml   # CI build + v1 release publishing
├── dylib/
│   ├── Makefile
│   ├── TweakRaw.xm                     # runtime localization implementation
│   ├── ZolaCN.plist                    # target bundle filter
│   └── build_embed.py                  # embeds translation table
├── Translations.plist                  # translation source table
├── VERSION                             # current release version
└── CHANGELOG.md
```

## Notes

This is the initial public version. Translation coverage depends on the bundled table and the UI paths used by the current Zalo build. Some dynamically generated or non-standard UI text may require additional hooks in future releases.
