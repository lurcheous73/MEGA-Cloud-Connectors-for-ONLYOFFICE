# MEGA S4 backend compile checkpoint — 2026-08-16

Branch: `feature/mega-s4`

Exact upstream baseline:

`ONLYOFFICE/CommunityServer@fe1fa7babd093969e939ba6ff45a9fee1299dc93`

## Result

The first-party MEGA S4 live-drive backend now compiles successfully inside the exact ONLYOFFICE CommunityServer 12.8 `ASC.Files.Thirdparty` build graph.

GitHub Actions run:

`31945454818` — **PASS**

The workflow:

1. checks out the connector branch;
2. checks out the exact CommunityServer 12.8 commit;
3. stages the `MegaS4` provider source;
4. applies deterministic exact-anchor integration changes;
5. restores the real project dependency graph;
6. builds `ASC.Files.Thirdparty` in Release configuration;
7. confirms the MEGA S4 provider source is present in the compiled project.

## Compile fixes proven by CI

- use `ASC.Files.Core.Security.FileShare` for third-party file access metadata;
- disambiguate overloaded `GetFile` LINQ method groups with explicit lambdas;
- use the AWS SDK `ByteRange(string)` form for open-ended range GETs (`bytes=<offset>-`);
- set `AmazonS3Config.AuthenticationRegion` from the MEGA S4 signing region (`g` by default);
- validate the selected bucket with `ListObjectsV2(MaxKeys=1)` instead of the obsolete ACL call.

## Scope of this checkpoint

This proves **source/build integration only**. It does not yet prove:

- Files UI connection form;
- bucket discovery in the connected-drive UI;
- credential persistence on a live portal;
- live browse/upload/download against MEGA S4;
- document open/edit/save-back;
- installer/rollback acceptance.

No live ONLYOFFICE installation is modified by this CI checkpoint.
