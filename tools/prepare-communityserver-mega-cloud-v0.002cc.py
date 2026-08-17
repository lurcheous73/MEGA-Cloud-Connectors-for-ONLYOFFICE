#!/usr/bin/env python3
"""BRIMSTONE CUSTOM CODE: add v0.002cc MEGA Cloud sources to prepared CommunityServer 12.8."""

from __future__ import annotations

import argparse
import pathlib

UTF8_BOM = b"\xef\xbb\xbf"


def load(path: pathlib.Path):
    raw = path.read_bytes()
    bom = raw.startswith(UTF8_BOM)
    if bom:
        raw = raw[len(UTF8_BOM):]
    text = raw.decode("utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    return text.replace("\r\n", "\n"), newline, bom


def save(path: pathlib.Path, text: str, newline: str, bom: bool):
    if newline != "\n":
        text = text.replace("\n", newline)
    raw = text.encode("utf-8")
    if bom:
        raw = UTF8_BOM + raw
    path.write_bytes(raw)


def replace_once(path: pathlib.Path, needle: str, replacement: str, description: str):
    text, newline, bom = load(path)
    count = text.count(needle)
    if count == 0:
        if replacement in text:
            print(f"PRESENT - {description}")
            return
        raise RuntimeError(f"anchor not found for {description}: {path}")
    if count != 1:
        raise RuntimeError(f"anchor occurs {count} times for {description}: {path}")
    save(path, text.replace(needle, replacement, 1), newline, bom)
    print(f"PATCHED - {description}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("communityserver_root", type=pathlib.Path)
    args = ap.parse_args()
    root = args.communityserver_root.resolve()

    project = root / "module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.csproj"
    cloud_dir = root / "module/ASC.Files.Thirdparty/BrimstoneMegaCloud"
    if not project.is_file():
        raise RuntimeError(f"CommunityServer project missing: {project}")
    if not cloud_dir.is_dir():
        raise RuntimeError(f"Brimstone MEGA Cloud source directory missing: {cloud_dir}")

    required = [
        "BrimstoneMegaCloudClient.cs",
        "BrimstoneMegaCloudDaoBase.cs",
        "BrimstoneMegaCloudDaoSelector.cs",
        "BrimstoneMegaCloudEntry.cs",
        "BrimstoneMegaCloudFileDao.cs",
        "BrimstoneMegaCloudFolderDao.cs",
        "BrimstoneMegaCloudId.cs",
        "BrimstoneMegaCloudLsParser.cs",
        "BrimstoneMegaCloudProviderInfo.cs",
        "BrimstoneMegaCloudSecurityDao.cs",
        "BrimstoneMegaCloudTagDao.cs",
    ]
    for name in required:
        if not (cloud_dir / name).is_file():
            raise RuntimeError(f"Brimstone MEGA Cloud source missing: {name}")

    anchor = '    <Compile Include="MegaS4\\MegaS4TagDao.cs" />'
    block = anchor + "\n" + "\n".join(
        f'    <Compile Include="BrimstoneMegaCloud\\{name}" />' for name in required
    )
    replace_once(project, anchor, block, "Brimstone MEGA Cloud v0.002cc compile items")

    print("PASS - Brimstone MEGA Cloud v0.002cc compile-only source integration applied")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL - {exc}")
        raise SystemExit(1)
