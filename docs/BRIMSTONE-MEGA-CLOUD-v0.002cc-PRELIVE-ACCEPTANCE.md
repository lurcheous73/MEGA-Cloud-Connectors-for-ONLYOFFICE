# BRIMSTONE MEGA Cloud v0.002cc — pre-live acceptance

Date: 2026-08-17

Branch at successful disposable smoke: `v0.002cc-mega-cloud`

Accepted source commit: `1a543f8b3a265743192927373de8ebd8b8fb1945`

## Scope

This acceptance covers the normal MEGA Cloud **read-only browse foundation** before any live ONLYOFFICE provider row is created.

It does not claim upload, rename, delete, file download/editor integration, UI connection flow, MFA runtime coverage, or editor save-back.

## Proven

- Official pinned MEGAcmd engine resumes a saved MEGA session without supplying a password again.
- Brimstone provider state is isolated by per-provider HOME and socket name.
- `BrimstoneMegaCloudProviderInfo.CheckAccess()` resumes a copied saved session and browses the MEGA root.
- `BrimstoneMegaCloudFolderDao` and `BrimstoneMegaCloudFileDao` instantiate successfully.
- Root browse returned three real handle-native folder entries through the Brimstone provider/DAO transport path.
- Nested browse returned eight folders and one file through a MEGA node handle.
- External ONLYOFFICE-safe IDs round-trip to MEGA node handles using the `sboxbrimstonemegacc-<providerId>-<handle>` namespace.
- `FolderDao.IsExist` resolved a known nested folder.
- `FileDao.IsExist` resolved a known nested file.
- Provider enum, provider materialisation, Brimstone state-slot handling, selector registration, and compile items are present in the prepared CommunityServer 12.8 source.
- The accepted MEGA S4 provider remains compiled in the combined `ASC.Files.Thirdparty.dll` candidate.
- v0.002cc Cloud write paths fail closed.
- Disposable smoke used a copy of the authenticated session. The original saved session hash was unchanged after the test.
- The live `ASC.Files.Thirdparty.dll` hash remained unchanged throughout disposable compile/runtime testing.
- ONLYOFFICE database was not touched by disposable testing.

## Successful disposable smoke candidate

The successful run produced candidate SHA-256:

`0765eeeac73c40f112dd13c067ff30520b1e2a0cdb93083e3825732ce5bc8465`

The candidate hash is a build artefact and may change on a clean rebuild; deployment must validate the freshly built candidate contract rather than assume this hash is reproducible.

## Live baseline before first Cloud deployment

Live `ASC.Files.Thirdparty.dll` SHA-256 observed immediately before and after the successful disposable smoke:

`62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f`

This is the protected pre-Cloud live baseline for the first controlled v0.002cc deployment.

## Deliberately deferred to live tenant-context test

ONLYOFFICE `Folder`/`File` object projection invokes tenant services such as `TenantUtil.DateTimeFromUtc(DateTime)`. A standalone reflection harness has no configured `CoreContext`; therefore projection is intentionally tested only inside a real CommunityServer tenant context and production code was not altered merely to satisfy the standalone harness.

## Privacy / secrets

This record intentionally contains no MEGA account identifier, password, session token, node handle, or user file/folder name.
