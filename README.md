# ZolaCN

Zalo iOS Chinese localization tweak.

## Build

This project is designed for GitHub Actions and Theos. The workflow builds rootless and rootful packages automatically.

### Rootless jailbreak
Download the `ZolaCN-rootless` artifact from GitHub Actions and install the generated package with your package manager.

### Rootful jailbreak
Use the `ZolaCN-rootful` artifact.

## What it does

Hooks `NSBundle localizedStringForKey:value:table:` and replaces Vietnamese/English localization strings with Chinese at runtime. The translation table is bundled as a resource, so the original Zalo.app does not need to be modified.

## Target

The tweak only loads for bundle identifier `vn.com.vng.zingalo`.
