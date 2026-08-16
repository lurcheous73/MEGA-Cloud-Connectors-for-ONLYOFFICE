# MEGA S4 Linux build validation checkpoint — 2026-08-16

This checkpoint records the first successful Linux/Mono build of the MEGA S4 `ASC.Files.Thirdparty.dll` against the exact ONLYOFFICE CommunityServer 12.8 runtime baseline used on the Grange `work` host.

## Exact baseline

- ONLYOFFICE CommunityServer image: `onlyoffice/communityserver:12.8.0.1971`
- CommunityServer source commit: `fe1fa7babd093969e939ba6ff45a9fee1299dc93`
- Connector branch before this checkpoint: `feature/mega-s4`
- Previous checkpoint commit: `56f26774b35e5b23c940599e96cb86207c05b3ae`

## Live stock hashes observed before any deployment

- `ASC.Files.Thirdparty.dll`: `0b7188ab9b94ee886814c96de7b678395596421cb46df6a9e541767aab01c89d`
- `thirdparty.js`: `c7bd83aaa28f02676e50b91a30d866e9366ec21565ee6a4f936649be65e50050`
- `getthirdpartyitem.xsl`: `b16b2e570a47693f1ac0f16112fd562d7ffd0eeef2f80a001e18ea36406fb646`
- Files production bundle: `1077a3c78a388d1c2a88fddb49d19af4019cebd9a86c7c25e7c82d1e9f555714`

## Runtime AWS assemblies already present in CommunityServer

- `AWSSDK.Core.dll` assembly version `4.0.0.0`
- `AWSSDK.S3.dll` assembly version `4.0.0.0`

The MEGA S4 provider DLL references both assemblies at version `4.0.0.0`. They are runtime dependencies. The installer must validate them before deployment and must not silently replace them when the expected runtime assemblies are already present.

## Linux/Mono build issue and resolution

The stock Mono/.NET Framework 4.8 reference set exposed `System.Net.Http` assembly version `4.1.1.3`, while `Microsoft.Graph.Core 1.6.0.0` requires `System.Net.Http 4.2.0.0`. This caused `CS1705` even though the MEGA S4 code itself compiled successfully on the Windows Server 2022 GitHub Actions build.

The validated Linux build uses the build-only package:

`Microsoft.NETFramework.ReferenceAssemblies.net48` version `1.0.3`

Its .NET Framework 4.8 reference assembly supplies `System.Net.Http` version `4.2.0.0`. This package is compiler scaffolding only and must not be copied into the live WebStudio `bin` directory.

## Successful Linux build output

Observed candidate:

- file: `ASC.Files.Thirdparty.dll`
- size: `267264` bytes
- SHA-256: `98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01`
- assembly name: `ASC.Files.Thirdparty`
- assembly version: `1.0.0.0`

The exact hash is a recorded checkpoint for this build. Future compiler/toolchain changes may legitimately produce a different binary hash, so deployment must also validate CLR metadata rather than relying on the hash alone.

## Required CLR metadata validation

`monodis --typedef` successfully identified all required provider types:

- `MegaS4Auth`
- `MegaS4DaoSelector`
- `MegaS4ProviderInfo`
- `MegaS4Storage`
- `MegaS4FileDao`
- `MegaS4FolderDao`
- `MegaS4SecurityDao`
- `MegaS4TagDao`

`monodis --assemblyref` confirmed:

- `AWSSDK.S3` version `4.0.0.0`
- `AWSSDK.Core` version `4.0.0.0`

GNU `strings` is not a valid acceptance test for managed CLR type metadata and must not be used as the deployment gate.

## Deployment rule

No live ONLYOFFICE file was modified while proving this checkpoint.

A live installer must fail closed unless all of the following are true before it changes production:

1. the CommunityServer image is the expected 12.8 image;
2. the live stock provider DLL and stock UI assets match their expected baselines, unless an explicitly supported already-installed state is detected;
3. the candidate DLL passes CLR type and AWS reference validation;
4. complete rollback copies are created and verified;
5. post-install application health and provider/UI markers pass;
6. any failed post-install check restores the original files automatically.
