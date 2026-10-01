#!/usr/bin/env python3
from __future__ import annotations

import gzip
import io
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
PKGROOT = ROOT / ".theos" / "deb-package"
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()

if not VERSION:
    raise SystemExit("VERSION is empty")

DYLIB = DIST / "ZolaCN.dylib"
PLIST = ROOT / "dylib" / "ZolaCN.plist"

if not DYLIB.is_file():
    raise SystemExit(f"Missing built dylib: {DYLIB}")
if not PLIST.is_file():
    raise SystemExit(f"Missing package filter: {PLIST}")

CONTROL = f"""Package: com.fadedrk.zolacn
Name: ZolaCN
Version: {VERSION}
Architecture: iphoneos-arm64
Maintainer: FadedRK
Section: Tweaks
Priority: optional
Description: ZolaCN Chinese localization, anti-recall, and theme enhancements for Zalo.
Homepage: https://github.com/FadedRK/ZolaCN
""".encode("utf-8")


def control_tar_gz() -> bytes:
    info = tarfile.TarInfo("control")
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mode = 0o644
    info.mtime = 0
    info.size = len(CONTROL)

    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as stream:
        with tarfile.open(fileobj=stream, mode="w") as archive:
            archive.addfile(info, io.BytesIO(CONTROL))
    return raw.getvalue()


def data_tar_gz(files: list[tuple[Path, str]]) -> bytes:
    raw = io.BytesIO()

    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as stream:
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for source, arcname in files:
                info = archive.gettarinfo(str(source), arcname=arcname)
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0

                with source.open("rb") as input_stream:
                    archive.addfile(info, input_stream)

    return raw.getvalue()


def ar_member(name: str, data: bytes) -> bytes:
    name_field = (name + "/")[:16].ljust(16)
    header = (
        f"{name_field}"
        f"{0:<12}"
        f"{0:<6}"
        f"{0:<6}"
        f"{0o100644:<8o}"
        f"{len(data):<10}"
    ).encode("ascii") + bytes([96, 10])

    if len(header) != 60:
        raise ValueError(f"Invalid ar header length: {len(header)}")

    return header + data + (b"\n" if len(data) % 2 else b"")


def build_deb() -> Path:
    package_root = PKGROOT / "Library" / "MobileSubstrate" / "DynamicLibraries"
    package_root.mkdir(parents=True, exist_ok=True)

    package_dylib = package_root / "ZolaCN.dylib"
    package_plist = package_root / "ZolaCN.plist"

    package_dylib.write_bytes(DYLIB.read_bytes())
    package_plist.write_bytes(PLIST.read_bytes())

    control_data = control_tar_gz()
    data_data = data_tar_gz(
        [
            (package_dylib, "Library/MobileSubstrate/DynamicLibraries/ZolaCN.dylib"),
            (package_plist, "Library/MobileSubstrate/DynamicLibraries/ZolaCN.plist"),
        ]
    )

    output = DIST / f"com.fadedrk.zolacn_{VERSION}_iphoneos-arm64.deb"
    output.parent.mkdir(parents=True, exist_ok=True)

    with output.open("wb") as stream:
        stream.write(b"!<arch>\n")
        stream.write(ar_member("debian-binary", b"2.0\n"))
        stream.write(ar_member("control.tar.gz", control_data))
        stream.write(ar_member("data.tar.gz", data_data))

    print(f"Built {output}")
    print(f"Package size: {output.stat().st_size} bytes")
    print(f"control.tar.gz: {len(control_data)} bytes")
    print(f"data.tar.gz: {len(data_data)} bytes")

    return output


if __name__ == "__main__":
    build_deb()
