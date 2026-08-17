#!/usr/bin/env python3
"""BRIMSTONE CUSTOM CODE: wire v0.002cc MEGA Cloud into prepared CommunityServer 12.8."""

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

    account = root / "module/ASC.Files.Thirdparty/ProviderAccountDao.cs"
    provider_base = root / "module/ASC.Files.Thirdparty/ProviderDao/ProviderDaoBase.cs"
    project = root / "module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.csproj"
    cloud_dir = root / "module/ASC.Files.Thirdparty/BrimstoneMegaCloud"

    for path in (account, provider_base, project):
        if not path.is_file():
            raise RuntimeError(f"CommunityServer integration file missing: {path}")
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

    # BRIMSTONE: the S4 source preparer runs immediately before this script, so
    # these anchors deliberately target the already-prepared S4 integration.
    replace_once(
        account,
        "using ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "using ASC.Files.Thirdparty.BrimstoneMegaCloud;\nusing ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "ProviderAccountDao Brimstone MEGA Cloud namespace import",
    )

    replace_once(
        account,
        "            GoogleDrive,\n            MegaS4,\n            OneDrive,",
        "            GoogleDrive,\n            BrimstoneMegaCloud,\n            MegaS4,\n            OneDrive,",
        "ProviderAccountDao Brimstone MEGA Cloud provider enum",
    )

    mega_materialisation = """            // BRIMSTONE CUSTOM CODE: MEGA S4 provider materialisation.
            if (key == ProviderTypes.MegaS4)
"""
    cloud_materialisation = """            // BRIMSTONE CUSTOM CODE: normal MEGA Cloud provider materialisation.
            // token is ONLY a non-secret Brimstone state-slot locator. The
            // actual MEGA resumable session remains below the protected HOME.
            if (key == ProviderTypes.BrimstoneMegaCloud)
            {
                return new BrimstoneMegaCloudProviderInfo(
                    id,
                    key.ToString(),
                    providerTitle,
                    token,
                    owner,
                    folderType,
                    createOn);
            }

""" + mega_materialisation
    replace_once(
        account,
        mega_materialisation,
        cloud_materialisation,
        "ProviderAccountDao Brimstone MEGA Cloud materialisation",
    )

    replace_once(
        account,
        "                case ProviderTypes.SharePoint:\n                case ProviderTypes.WebDav:\n                case ProviderTypes.MegaS4:\n                    break;",
        "                case ProviderTypes.SharePoint:\n                case ProviderTypes.WebDav:\n                case ProviderTypes.BrimstoneMegaCloud:\n                case ProviderTypes.MegaS4:\n                    break;",
        "ProviderAccountDao Brimstone MEGA Cloud state-slot handling",
    )

    replace_once(
        provider_base,
        "using ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "using ASC.Files.Thirdparty.BrimstoneMegaCloud;\nusing ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "ProviderDaoBase Brimstone MEGA Cloud namespace import",
    )

    selector_anchor = """            // BRIMSTONE CUSTOM CODE: MEGA S4 connected-drive selector.
            Selectors.Add(new MegaS4DaoSelector());"""
    selector_block = selector_anchor + """
            // BRIMSTONE CUSTOM CODE: normal MEGA Cloud connected-drive selector.
            Selectors.Add(new BrimstoneMegaCloudDaoSelector());"""
    replace_once(
        provider_base,
        selector_anchor,
        selector_block,
        "ProviderDaoBase Brimstone MEGA Cloud selector registration",
    )

    anchor = '    <Compile Include="MegaS4\\MegaS4TagDao.cs" />'
    block = anchor + "\n" + "\n".join(
        f'    <Compile Include="BrimstoneMegaCloud\\{name}" />' for name in required
    )
    replace_once(project, anchor, block, "Brimstone MEGA Cloud v0.002cc compile items")

    print("PASS - Brimstone MEGA Cloud v0.002cc provider registration and compile integration applied")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL - {exc}")
        raise SystemExit(1)
