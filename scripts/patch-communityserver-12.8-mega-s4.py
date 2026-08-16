#!/usr/bin/env python3
"""Patch the exact ONLYOFFICE CommunityServer 12.8 baseline for MEGA S4.

This intentionally uses exact, one-occurrence text anchors rather than a fuzzy
patch.  If upstream moves, the script stops instead of silently modifying the
wrong code.  It is idempotent for CI/developer re-runs.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

EXPECTED_COMMIT = "fe1fa7babd093969e939ba6ff45a9fee1299dc93"


def run_checked(cwd: pathlib.Path, *args: str) -> str:
    proc = subprocess.run(
        list(args),
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.stdout:
        print(proc.stdout, end="")
    if proc.returncode:
        raise RuntimeError(f"{' '.join(args)} failed with exit code {proc.returncode}")
    return proc.stdout.strip()


def read_normalized(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n")


def write_normalized(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def replace_once(path: pathlib.Path, needle: str, replacement: str, description: str) -> None:
    text = read_normalized(path)
    count = text.count(needle)
    if count == 0:
        if replacement in text:
            print(f"PRESENT - {description}")
            return
        raise RuntimeError(f"Anchor not found for {description}: {path}")
    if count != 1:
        raise RuntimeError(f"Anchor occurs {count} times for {description}: {path}")
    write_normalized(path, text.replace(needle, replacement, 1))
    print(f"PATCHED - {description}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("communityserver_root", type=pathlib.Path)
    args = parser.parse_args()

    root = args.communityserver_root.resolve()
    if not (root / ".git").exists():
        raise RuntimeError(f"Not a CommunityServer git checkout: {root}")

    head = run_checked(root, "git", "rev-parse", "HEAD").splitlines()[-1].strip()
    if head != EXPECTED_COMMIT:
        raise RuntimeError(f"CommunityServer baseline mismatch: expected {EXPECTED_COMMIT}, got {head}")

    account = root / "module/ASC.Files.Thirdparty/ProviderAccountDao.cs"
    provider_base = root / "module/ASC.Files.Thirdparty/ProviderDao/ProviderDaoBase.cs"
    project = root / "module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.csproj"

    replace_once(
        account,
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.OneDrive;",
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "ProviderAccountDao MEGA S4 namespace import",
    )

    replace_once(
        account,
        "            GoogleDrive,\n            OneDrive,",
        "            GoogleDrive,\n            MegaS4,\n            OneDrive,",
        "ProviderAccountDao MegaS4 provider enum",
    )

    one_drive_block = """            if (key == ProviderTypes.OneDrive)
            {
                return new OneDriveProviderInfo(
                    id,
                    key.ToString(),
                    providerTitle,
                    token,
                    owner,
                    folderType,
                    createOn);
            }
"""
    mega_block = one_drive_block + """
            if (key == ProviderTypes.MegaS4)
            {
                string megaS4Secret;
                try
                {
                    megaS4Secret = DecryptPassword(input[4] as string);
                }
                catch (Exception e)
                {
                    Global.Logger.Error(string.Format("DecryptPassword error: linkId = {0} , user = {1}", id, SecurityContext.CurrentAccount.ID), e);
                    return null;
                }

                return new MegaS4ProviderInfo(
                    id,
                    key.ToString(),
                    providerTitle,
                    input[3] as string,
                    megaS4Secret,
                    input[9] as string,
                    token,
                    owner,
                    folderType,
                    createOn);
            }
"""
    replace_once(
        account,
        one_drive_block,
        mega_block,
        "ProviderAccountDao MegaS4 provider materialisation",
    )

    replace_once(
        account,
        "                case ProviderTypes.SharePoint:\n                case ProviderTypes.WebDav:\n                    break;",
        "                case ProviderTypes.SharePoint:\n                case ProviderTypes.WebDav:\n                case ProviderTypes.MegaS4:\n                    break;",
        "ProviderAccountDao MegaS4 raw credential handling",
    )

    replace_once(
        provider_base,
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.OneDrive;",
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "ProviderDaoBase MEGA S4 namespace import",
    )

    replace_once(
        provider_base,
        "            Selectors.Add(new DropboxDaoSelector());\n            Selectors.Add(new OneDriveDaoSelector());",
        "            Selectors.Add(new DropboxDaoSelector());\n            Selectors.Add(new OneDriveDaoSelector());\n            Selectors.Add(new MegaS4DaoSelector());",
        "ProviderDaoBase MEGA S4 selector registration",
    )

    compile_anchor = '    <Compile Include="GoogleDrive\\GoogleDriveTagDao.cs" />'
    compile_block = compile_anchor + """
    <Compile Include="MegaS4\\MegaS4Auth.cs" />
    <Compile Include="MegaS4\\MegaS4DaoBase.cs" />
    <Compile Include="MegaS4\\MegaS4DaoSelector.cs" />
    <Compile Include="MegaS4\\MegaS4Entry.cs" />
    <Compile Include="MegaS4\\MegaS4FileDao.cs" />
    <Compile Include="MegaS4\\MegaS4FolderDao.cs" />
    <Compile Include="MegaS4\\MegaS4Id.cs" />
    <Compile Include="MegaS4\\MegaS4Options.cs" />
    <Compile Include="MegaS4\\MegaS4ProviderInfo.cs" />
    <Compile Include="MegaS4\\MegaS4SecurityDao.cs" />
    <Compile Include="MegaS4\\MegaS4Storage.cs" />
    <Compile Include="MegaS4\\MegaS4TagDao.cs" />"""
    replace_once(
        project,
        compile_anchor,
        compile_block,
        "ASC.Files.Thirdparty MEGA S4 compile items",
    )

    package_anchor = """  <ItemGroup>
    <PackageReference Include="AppLimit.CloudComputing.SharpBox">"""
    package_block = """  <ItemGroup>
    <PackageReference Include="AWSSDK.S3">
      <Version>4.0.19.2</Version>
    </PackageReference>
    <PackageReference Include="AppLimit.CloudComputing.SharpBox">"""
    replace_once(
        project,
        package_anchor,
        package_block,
        "ASC.Files.Thirdparty AWSSDK.S3 dependency",
    )

    run_checked(root, "git", "diff", "--check")
    print("\nPASS - deterministic MEGA S4 backend integration patch applied to CommunityServer 12.8.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL - {exc}", file=sys.stderr)
        raise SystemExit(1)
