#!/usr/bin/env python3
"""BRIMSTONE CUSTOM CODE: prepare exact CommunityServer 12.8 source for MEGA S4."""

from __future__ import annotations

import argparse
import pathlib
import subprocess

EXPECTED_COMMIT = "fe1fa7babd093969e939ba6ff45a9fee1299dc93"
UTF8_BOM = b"\xef\xbb\xbf"


def run(cwd: pathlib.Path, *args: str) -> str:
    p = subprocess.run(args, cwd=str(cwd), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.stdout:
        print(p.stdout, end="")
    if p.returncode:
        raise RuntimeError(f"{' '.join(args)} failed with exit code {p.returncode}")
    return p.stdout.strip()


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

    if not (root / ".git").exists():
        raise RuntimeError(f"not a CommunityServer git checkout: {root}")
    head = run(root, "git", "rev-parse", "HEAD").splitlines()[-1].strip()
    if head != EXPECTED_COMMIT:
        raise RuntimeError(f"CommunityServer baseline mismatch: expected {EXPECTED_COMMIT}, got {head}")

    account = root / "module/ASC.Files.Thirdparty/ProviderAccountDao.cs"
    provider_base = root / "module/ASC.Files.Thirdparty/ProviderDao/ProviderDaoBase.cs"
    project = root / "module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.csproj"

    # Always start from the exact upstream versions of the integration files.
    run(root, "git", "checkout", EXPECTED_COMMIT, "--",
        "module/ASC.Files.Thirdparty/ProviderAccountDao.cs",
        "module/ASC.Files.Thirdparty/ProviderDao/ProviderDaoBase.cs",
        "module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.csproj")

    replace_once(account,
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.OneDrive;",
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "ProviderAccountDao MEGA S4 namespace import")

    replace_once(account,
        "            GoogleDrive,\n            OneDrive,",
        "            GoogleDrive,\n            MegaS4,\n            OneDrive,",
        "ProviderAccountDao MegaS4 provider enum")

    one_drive = """            if (key == ProviderTypes.OneDrive)
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
    mega = one_drive + """

            // BRIMSTONE CUSTOM CODE: MEGA S4 provider materialisation.
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
    replace_once(account, one_drive, mega, "ProviderAccountDao MegaS4 materialisation")

    replace_once(account,
        "                case ProviderTypes.SharePoint:\n                case ProviderTypes.WebDav:\n                    break;",
        "                case ProviderTypes.SharePoint:\n                case ProviderTypes.WebDav:\n                case ProviderTypes.MegaS4:\n                    break;",
        "ProviderAccountDao MegaS4 raw credential handling")

    save_anchor = """            authData = GetEncodedAccesToken(authData, prKey);

            if (!CheckProviderInfo(ToProviderInfo(0, providerKey, customerTitle, authData, SecurityContext.CurrentAccount.ID.ToString(), folderType, TenantUtil.DateTimeToUtc(TenantUtil.DateTimeNow()))))
"""
    save_replacement = """            authData = GetEncodedAccesToken(authData, prKey);

            // BRIMSTONE CUSTOM CODE: resolve a one-time import from the shared
            // S3Compatible AuthorizationKeys consumer before validation/persist.
            if (prKey == ProviderTypes.MegaS4)
                authData = BrimstoneMegaS4Secrets.ResolveForProviderSave(authData);

            if (!CheckProviderInfo(ToProviderInfo(0, providerKey, customerTitle, authData, SecurityContext.CurrentAccount.ID.ToString(), folderType, TenantUtil.DateTimeToUtc(TenantUtil.DateTimeNow()))))
"""
    replace_once(account, save_anchor, save_replacement,
                 "ProviderAccountDao Brimstone shared credential import")

    replace_once(provider_base,
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.OneDrive;",
        "using ASC.Files.Thirdparty.GoogleDrive;\nusing ASC.Files.Thirdparty.MegaS4;\nusing ASC.Files.Thirdparty.OneDrive;",
        "ProviderDaoBase MEGA S4 namespace import")

    replace_once(provider_base,
        "            Selectors.Add(new DropboxDaoSelector());\n            Selectors.Add(new OneDriveDaoSelector());",
        "            Selectors.Add(new DropboxDaoSelector());\n            Selectors.Add(new OneDriveDaoSelector());\n            // BRIMSTONE CUSTOM CODE: MEGA S4 connected-drive selector.\n            Selectors.Add(new MegaS4DaoSelector());",
        "ProviderDaoBase MEGA S4 selector registration")

    compile_anchor = '    <Compile Include="GoogleDrive\\GoogleDriveTagDao.cs" />'
    compile_block = compile_anchor + """
    <Compile Include="MegaS4\\BrimstoneMegaS4Handler.cs" />
    <Compile Include="MegaS4\\BrimstoneMegaS4Secrets.cs" />
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
    replace_once(project, compile_anchor, compile_block,
                 "ASC.Files.Thirdparty Brimstone MEGA S4 compile items")

    package_anchor = """  <ItemGroup>
    <PackageReference Include="AppLimit.CloudComputing.SharpBox">"""
    package_block = """  <ItemGroup>
    <PackageReference Include="AWSSDK.S3">
      <Version>4.0.19.2</Version>
    </PackageReference>
    <PackageReference Include="AppLimit.CloudComputing.SharpBox">"""
    replace_once(project, package_anchor, package_block,
                 "ASC.Files.Thirdparty AWSSDK.S3 dependency")

    run(root, "git", "-c", "core.whitespace=cr-at-eol", "diff", "--check")
    print("PASS - deterministic Brimstone MEGA S4 integration applied to CommunityServer 12.8")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL - {exc}")
        raise SystemExit(1)
