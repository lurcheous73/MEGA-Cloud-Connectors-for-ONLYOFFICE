# BRIMSTONE MEGA S4 v1.0.0 status

Release date: 2026-08-16
Upstream CommunityServer baseline: `ONLYOFFICE/CommunityServer@fe1fa7babd093969e939ba6ff45a9fee1299dc93`

## Release state — WORKING V1

MEGA S4 is accepted as a working ONLYOFFICE live connected drive.

Live `ASC.Files.Thirdparty.dll` SHA256:

`62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f`

Provider ID namespace:

- root: `sboxmega-<providerId>`
- object/folder: `sboxmega-<providerId>-<base64url-key>`

## Working acceptance

- Manual access key + secret key authentication works.
- `Pull buckets` works with manually entered credentials.
- Multiple buckets returned by the S3 account can be selected and connected separately.
- Provider Save persists MEGA S4 accounts through the native ONLYOFFICE third-party account path.
- Bucket/prefix browsing works.
- Remote folder creation works.
- Upload to bucket root works.
- Upload to subfolders works.
- Remote objects can be viewed and downloaded.
- Documents open in the ONLYOFFICE editor.
- Edited documents save back to MEGA S4.
- Closing and reopening a document preserves the remote edits.
- Provider Delete has been proven.
- `CheckAccess()` validates the selected bucket before persistence.

## Native bucket-discovery handler — PROVEN

The helper endpoint is installed as a native precompiled ASP.NET handler:

- physical `/Products/Files/HttpHandlers/brimstone-megas4.ashx` is the stock precompilation marker;
- `/bin/brimstone-megas4.ashx.brimstone.compiled` maps directly to `ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler`;
- no explicit Brimstone `Web.config` handler mapping is required;
- the former Mono dynamic-parser `System.Runtime` failure is eliminated;
- authenticated Files UI bucket discovery is working.

## External MySQL protection — PROVEN

CommunityServer's two plain `mysqladmin shutdown` calls are protected with local-socket-only shutdown commands so CommunityServer restarts do not shut down the separate `onlyoffice-mysql-server` container.

Controlled acceptance left MySQL restart count unchanged at 35 and left the connector DLL hash unchanged.

## Known bug — ONE

**Shared S3-Compatible credential import can Pull buckets, but cannot currently Save the connection.**

With `Import existing S3-Compatible backup credentials` enabled, the server-side shared credential lookup succeeds and the bucket list is returned. Save is then blocked by the client-side MEGA S4 validation because the visible access-key and secret-key fields are intentionally blank/disabled in shared-import mode.

Manual typed credentials are unaffected: Pull buckets and Save both work normally.

This is the only bug listed for v1.0.0.

## Frozen recovery point

Known-good pre-release baseline:

`baseline/v0.005-99.9pct-20260816`

Exact commit:

`32c328654a6e266f51ab5e670be2fb224ce62a67`

Shared-import bug-fix development continues separately on `v0.006-shared-import`.
