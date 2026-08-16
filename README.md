# MEGA Cloud Connectors for ONLYOFFICE

## Brimstone baseline v0.001

This branch is the clean development baseline for the Brimstone MEGA S4 connected-drive work on ONLYOFFICE CommunityServer 12.8.

Everything added by this project must carry a clear `BRIMSTONE` / `Brimstone` marker in source, namespace, comments, identifiers, or documentation so custom code can be distinguished from upstream ONLYOFFICE code.

### Proven at this baseline

- MEGA S4 credentials are valid against `https://s3.g.megas4.com` using SigV4 region `g`.
- Direct signed `ListBuckets` returns HTTP 200.
- Direct signed `ListObjectsV2` against bucket `onlyoffice` returns HTTP 200.
- ONLYOFFICE can validate, persist and remove a MEGA S4 connected-account row.
- MEGA S4 credentials/token persistence uses the normal ONLYOFFICE third-party account path.
- Mapping-safe `sbox-megas4-<providerId>` IDs are retained.
- One-time import from the existing S3-Compatible backup credentials remains part of the design.

### Known broken / incomplete at v0.001

- Connected MEGA S4 root does not yet browse correctly in Files.
- `Pull buckets` `.ashx` helper currently produces an ASP.NET runtime error before returning Brimstone JSON.
- Existing-account edit UI falls back to the stock ONLYOFFICE Connection URL / Password form and must be replaced with the proper MEGA S4 editor.
- Full GET -> editor -> PUT round-trip has not yet been accepted.

### Deliberately removed

All experimental v2/v3/v4/v4.1/v4.2 deployment, rebuild, repair, upgrade and exact-hash scripts were removed from this baseline. They remain recoverable on the archive branch `archive/pre-v0.001-20260816`.

Start new work from `v0.001`. Do not resurrect old hotfix scripts unless a specific implementation detail is intentionally recovered from the archive.
