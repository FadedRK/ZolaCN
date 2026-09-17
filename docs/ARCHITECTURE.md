# ZolaCN Architecture

## Modules

### Localization

`Localization/ZLCNLocalization.*` owns the translation table, language selection, and UIKit fallback hooks.

Responsibilities:

- Load the embedded `Translations.plist` data.
- Translate runtime strings to Chinese when the selected language is `zh`.
- Preserve original Zalo text for `vi` / `en` when no independent translation source exists.
- Provide UIKit fallbacks for controls that do not pass through `NSBundle` localization.

### Recall

`Recall/ZARRecall.*` owns recall interception.

Current target:

```text
UndoChatProcessor
└── updateUndoMessageContent:
```

The hook tries to preserve content before Zalo's native recall mutation becomes visible. Lookup order is:

```text
originTextRecallMsg
      ↓
NSUserDefaults cached messageId content
      ↓
current message value
```

When content is recovered, a localized recall marker is appended. When recovery fails, the native Zalo implementation is called instead.

## Entry point

`Tweak.xm` only initializes configuration and modules. It should remain small so future changes stay isolated.

## Build-generated files

`TranslationsData.m` is generated from `Translations.plist` by `build_embed.py` and should not be edited manually.

## Future recall work

The current recall hook is a late-stage interception point. For stronger recall preservation, the next investigation target is an earlier normal-message lifecycle hook that can snapshot a populated message entity before recall processing.
