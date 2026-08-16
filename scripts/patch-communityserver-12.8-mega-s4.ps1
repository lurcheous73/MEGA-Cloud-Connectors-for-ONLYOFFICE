param(
    [Parameter(Mandatory = $false)]
    [string]$CommunityServerRoot = (Join-Path $PSScriptRoot '..\upstream')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ExpectedCommit = 'fe1fa7babd093969e939ba6ff45a9fee1299dc93'
$Root = (Resolve-Path $CommunityServerRoot).Path

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Read-Normalized {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Normalized {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Replace-ExactlyOnce {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Replacement,
        [string]$Description
    )

    $content = Read-Normalized $Path
    $first = $content.IndexOf($Needle, [System.StringComparison]::Ordinal)
    if ($first -lt 0) {
        if ($content.IndexOf($Replacement, [System.StringComparison]::Ordinal) -ge 0) {
            Write-Host "PRESENT - $Description"
            return
        }
        throw "Anchor not found for $Description in $Path"
    }

    $second = $content.IndexOf($Needle, $first + $Needle.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) {
        throw "Anchor is not unique for $Description in $Path"
    }

    $content = $content.Substring(0, $first) + $Replacement + $content.Substring($first + $Needle.Length)
    Write-Normalized $Path $content
    Write-Host "PATCHED - $Description"
}

Push-Location $Root
try {
    $head = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read CommunityServer git HEAD.' }
    if ($head -ne $ExpectedCommit) {
        throw "CommunityServer baseline mismatch. Expected $ExpectedCommit, got $head"
    }

    $accountDao = Join-Path $Root 'module\ASC.Files.Thirdparty\ProviderAccountDao.cs'
    $providerBase = Join-Path $Root 'module\ASC.Files.Thirdparty\ProviderDao\ProviderDaoBase.cs'
    $project = Join-Path $Root 'module\ASC.Files.Thirdparty\ASC.Files.Thirdparty.csproj'

    Replace-ExactlyOnce $accountDao `
        "using ASC.Files.Thirdparty.GoogleDrive;`nusing ASC.Files.Thirdparty.OneDrive;" `
        "using ASC.Files.Thirdparty.GoogleDrive;`nusing ASC.Files.Thirdparty.MegaS4;`nusing ASC.Files.Thirdparty.OneDrive;" `
        'ProviderAccountDao MEGA S4 namespace import'

    Replace-ExactlyOnce $accountDao `
        "            GoogleDrive,`n            OneDrive," `
        "            GoogleDrive,`n            MegaS4,`n            OneDrive," `
        'ProviderAccountDao MegaS4 provider enum'

    $oneDriveBlock = @'
            if (key == ProviderTypes.OneDrive)
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
'@

    $megaBlock = @'
            if (key == ProviderTypes.OneDrive)
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
'@
    Replace-ExactlyOnce $accountDao $oneDriveBlock $megaBlock 'ProviderAccountDao MegaS4 provider materialisation'

    Replace-ExactlyOnce $accountDao `
        "                case ProviderTypes.SharePoint:`n                case ProviderTypes.WebDav:`n                    break;" `
        "                case ProviderTypes.SharePoint:`n                case ProviderTypes.WebDav:`n                case ProviderTypes.MegaS4:`n                    break;" `
        'ProviderAccountDao MegaS4 raw credential handling'

    Replace-ExactlyOnce $providerBase `
        "using ASC.Files.Thirdparty.GoogleDrive;`nusing ASC.Files.Thirdparty.OneDrive;" `
        "using ASC.Files.Thirdparty.GoogleDrive;`nusing ASC.Files.Thirdparty.MegaS4;`nusing ASC.Files.Thirdparty.OneDrive;" `
        'ProviderDaoBase MEGA S4 namespace import'

    Replace-ExactlyOnce $providerBase `
        "            Selectors.Add(new DropboxDaoSelector());`n            Selectors.Add(new OneDriveDaoSelector());" `
        "            Selectors.Add(new DropboxDaoSelector());`n            Selectors.Add(new OneDriveDaoSelector());`n            Selectors.Add(new MegaS4DaoSelector());" `
        'ProviderDaoBase MEGA S4 selector registration'

    $compileAnchor = '    <Compile Include="GoogleDrive\GoogleDriveTagDao.cs" />'
    $compileBlock = @'
    <Compile Include="GoogleDrive\GoogleDriveTagDao.cs" />
    <Compile Include="MegaS4\MegaS4Auth.cs" />
    <Compile Include="MegaS4\MegaS4DaoBase.cs" />
    <Compile Include="MegaS4\MegaS4DaoSelector.cs" />
    <Compile Include="MegaS4\MegaS4Entry.cs" />
    <Compile Include="MegaS4\MegaS4FileDao.cs" />
    <Compile Include="MegaS4\MegaS4FolderDao.cs" />
    <Compile Include="MegaS4\MegaS4Id.cs" />
    <Compile Include="MegaS4\MegaS4Options.cs" />
    <Compile Include="MegaS4\MegaS4ProviderInfo.cs" />
    <Compile Include="MegaS4\MegaS4SecurityDao.cs" />
    <Compile Include="MegaS4\MegaS4Storage.cs" />
    <Compile Include="MegaS4\MegaS4TagDao.cs" />
'@
    Replace-ExactlyOnce $project $compileAnchor $compileBlock 'ASC.Files.Thirdparty MEGA S4 compile items'

    Replace-ExactlyOnce $project `
        "  <ItemGroup>`n    <PackageReference Include=\"AppLimit.CloudComputing.SharpBox\">" `
        "  <ItemGroup>`n    <PackageReference Include=\"AWSSDK.S3\">`n      <Version>4.0.19.2</Version>`n    </PackageReference>`n    <PackageReference Include=\"AppLimit.CloudComputing.SharpBox\">" `
        'ASC.Files.Thirdparty AWSSDK.S3 dependency'

    Invoke-NativeChecked git diff --check

    Write-Host ''
    Write-Host 'PASS - deterministic MEGA S4 backend integration patch applied to CommunityServer 12.8.'
}
finally {
    Pop-Location
}
