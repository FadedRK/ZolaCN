#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n ' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
PKGROOT="$ROOT/.theos/deb-package"

rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/DEBIAN"
mkdir -p "$PKGROOT/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$DIST"

test -f "$DIST/ZolaCN.dylib"

cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: com.fadedrk.zolacn
Name: ZolaCN
Version: $VERSION
Architecture: iphoneos-arm64
Maintainer: FadedRK
Section: Tweaks
Priority: optional
Description: ZolaCN Chinese localization, anti-recall, and theme enhancements for Zalo.
Homepage: https://github.com/FadedRK/ZolaCN
EOF

cp "$DIST/ZolaCN.dylib" "$PKGROOT/Library/MobileSubstrate/DynamicLibraries/ZolaCN.dylib"
cp "$ROOT/dylib/ZolaCN.plist" "$PKGROOT/Library/MobileSubstrate/DynamicLibraries/ZolaCN.plist"

printf '2.0\n' > "$PKGROOT/debian-binary"

tar -C "$PKGROOT/DEBIAN" -czf "$PKGROOT/control.tar.gz" control
tar -C "$PKGROOT" \
  --exclude='DEBIAN' \
  --exclude='debian-binary' \
  --exclude='control.tar.gz' \
  --exclude='data.tar.gz' \
  -czf "$PKGROOT/data.tar.gz" Library

DEB="$DIST/com.fadedrk.zolacn_$VERSION"_"iphoneos-arm64.deb"
rm -f "$DEB"

(
  cd "$PKGROOT"
  /usr/bin/ar -cr "$DEB" debian-binary control.tar.gz data.tar.gz
)

file "$DEB"
ls -lh "$DEB"
