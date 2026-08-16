# BRIMSTONE MEGA S4 v0.002 status

Baseline date: 2026-08-16
Upstream CommunityServer baseline: `ONLYOFFICE/CommunityServer@fe1fa7babd093969e939ba6ff45a9fee1299dc93`

## External MEGA S4 transport — PROVEN

Using burnable test credentials and an independently constructed SigV4 request:

- `GET https://s3.g.megas4.com/` -> HTTP 200 `ListAllMyBucketsResult`.
- `GET https://s3.g.megas4.com/onlyoffice?list-type=2&max-keys=5` -> HTTP 200 `ListBucketResult`.
- The Amsterdam endpoint also returned HTTP 200, but the connector baseline remains the global `g` endpoint and signing region `g`.

## v0.002 live candidate — PROVEN

Live `ASC.Files.Thirdparty.dll` SHA256:

`11864dfba74e7299b407439b54b4fc0fcfb3b7db32bb9526dd889b2476ae7c54`

The v0.002 provider ID namespace is browser-compatible:

- root: `sboxmega-<providerId>`
- object/folder: `sboxmega-<providerId>-<base64url-key>`

This satisfies ONLYOFFICE's browser-side third-party ID grammar, still enters the native `StartsWith("sbox")` MappingID path, and cannot match stock SharpBox's `^sbox-\d+...` selector.

## ONLYOFFICE integration — PROVEN

- MEGA S4 provider source compiles into `ASC.Files.Thirdparty.dll`.
- Manual credentials plus a manually entered bucket name save successfully.
- Provider Save persists a MEGA S4 account.
- The saved MEGA S4 root opens normally in Files.
- Bucket/prefix browsing works.
- A folder named `test` created in ONLYOFFICE appeared in the real MEGA S4 `onlyoffice` bucket, proving a remote write round-trip for folder creation.
- Provider Delete has previously been proven.
- `CheckAccess()` validates the selected bucket using `ListObjectsV2` before persistence.

## Known remaining bugs

1. **Bucket helper** — `Pull buckets` still fails because `/Products/Files/HttpHandlers/brimstone-megas4.ashx` returns the ASP.NET Runtime Error page before Brimstone JSON. This affects both manual credentials and the shared S3-Compatible credential-import helper. Manual bucket entry remains functional.
2. **Existing account editor** — existing MEGA accounts still need a proper Brimstone editor rather than the stock Connection URL / Password / Folder title form.
3. **Shared credential import UX** — server-side import is retained, but bucket discovery through the broken helper is not yet usable. Test Save separately from bucket discovery before declaring this path complete.

## Acceptance progress

1. Connect MEGA S4 account — PASS (manual credentials/manual bucket).
2. Browse bucket/prefix tree — PASS.
3. Create remote folder from ONLYOFFICE — PASS.
4. Download arbitrary object — NEXT.
5. Upload arbitrary object — NEXT.
6. Open DOCX in ONLYOFFICE editor — NEXT.
7. Save changes back to MEGA S4 — NEXT.
8. Reopen and verify remote persistence — NEXT.

## Archive

Pre-cleanup experimentation is preserved at `archive/pre-v0.001-20260816`.
