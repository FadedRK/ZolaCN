# ZolaCN

ZolaCN is a modular iOS tweak for Zalo, focused on runtime Chinese localization and recall-message preservation.

## Features

### Chinese localization

- Runtime translation of Zalo UI text to Chinese.
- Embedded translation table generated from `Translations.plist`.
- UIKit fallback hooks for labels, buttons, navigation items, tab items, search placeholders, and text-field placeholders.
- Built-in translation overrides for common Zalo actions and recall-related strings.
- Supports `arm64` and `arm64e`.

### Recall preservation

- Hooks `UndoChatProcessor.updateUndoMessageContent:`.
- Supports both self-recall and other-party recall paths.
- Attempts to preserve the original message from `originTextRecallMsg`, cached content, or the current entity content.
- Adds a localized recall marker below preserved content.
- Controlled by `ZolaAntiRecallEnabled` and `ZolaAntiRecallShowMyRecall`.
- Falls back to Zalo's native implementation when the hook cannot safely preserve the message.

> The recall hook is runtime-dependent and should be verified against the target Zalo version. It is not guaranteed to work unchanged across future Zalo updates.

## Install

The public release artifact is `ZolaCN.dylib`.

1. Download the latest dylib from **[GitHub Releases](https://github.com/FadedRK/ZolaCN/releases)**.
2. Open TrollFools and select Zalo.
3. Inject `ZolaCN.dylib`.
4. Completely terminate Zalo and launch it again.

Target bundle identifier:

```text
vn.com.vng.zingalo
```

No Debian package is required.

## Build

GitHub Actions builds the standalone dylib using Theos.

```bash
python3 dylib/build_embed.py
make -C dylib
```

The build embeds `Translations.plist` into `TranslationsData.m` and produces:

```text
ZolaCN.dylib
```

## Project layout

```text
ZolaCN/
├── .github/workflows/
│   └── build-dylib.yml              # CI build + release publishing
├── dylib/
│   ├── Tweak.xm                     # module entry point
│   ├── Makefile                     # Theos build definition
│   ├── Localization/
│   │   ├── ZLCNLocalization.h
│   │   └── ZLCNLocalization.m       # translation + UIKit hooks
│   ├── Recall/
│   │   ├── ZARRecall.h
│   │   └── ZARRecall.m               # recall interception/preservation
│   ├── ZolaCN.plist                  # target bundle filter
│   └── build_embed.py                # translation table embedding
├── Translations.plist                # translation source table
├── VERSION                           # current release version
└── CHANGELOG.md                      # release history
```

## Runtime flow

```text
ZolaCN
  │
  ├── Localization
  │     ├── load translation table
  │     ├── NSBundle localization hook
  │     └── UIKit fallback hooks
  │
  └── Recall
        └── UndoChatProcessor.updateUndoMessageContent:
              ├── self / other recall detection
              ├── original content lookup
              ├── localized recall marker
              └── safe fallback to native Zalo behavior
```

## Configuration

Settings are stored in `NSUserDefaults`:

```text
ZolaCNLanguage
ZolaAntiRecallEnabled
ZolaAntiRecallShowMyRecall
```

Supported language values:

```text
zh
vi
en
```

The localization table currently provides the Chinese translation source. Vietnamese and English use the original Zalo text as the fallback.

## Compatibility

The tweak targets the Zalo bundle `vn.com.vng.zingalo` and currently builds for `arm64` / `arm64e` on iOS 15.0+ target SDK settings.

Because the recall implementation relies on private runtime classes and selectors, Zalo updates may require method or model adjustments.
