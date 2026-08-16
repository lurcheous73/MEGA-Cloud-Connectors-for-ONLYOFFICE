# BRIMSTONE MEGA S4 v0.001 status

Baseline date: 2026-08-16
Upstream CommunityServer baseline: `ONLYOFFICE/CommunityServer@fe1fa7babd093969e939ba6ff45a9fee1299dc93`

## External MEGA S4 transport — PROVEN

Using burnable test credentials and an independently constructed SigV4 request:

- `GET https://s3.g.megas4.com/` -> HTTP 200 `ListAllMyBucketsResult`.
- `GET https://s3.g.megas4.com/onlyoffice?list-type=2&max-keys=5` -> HTTP 200 `ListBucketResult`.
- The `onlyoffice` bucket exists and was empty during the test.
- The Amsterdam endpoint also returned HTTP 200, but the connector baseline remains the global `g` endpoint and signing region `g`.

Therefore current failures are ONLYOFFICE integration failures, not credential, bucket, endpoint or MEGA S4 availability failures.

## ONLYOFFICE integration — PROVEN

- MEGA S4 provider source compiles into `ASC.Files.Thirdparty.dll`.
- Provider Save reaches HTTP 200 and persists a MEGA S4 account.
- Provider Delete reaches HTTP 200 and removes it.
- `CheckAccess()` validates the selected bucket using `ListObjectsV2` before persistence.
- `InvalidateStorage()` no longer writes null into `DisposableHttpContext`.
- Provider IDs use `sbox-megas4-<providerId>` to participate in ONLYOFFICE's mapping-safe path without matching stock SharpBox selectors.

## NEXT THREE BUGS

1. **Root navigation** — clicking the saved MEGA S4 root does not produce a usable drive view although the DAO's empty-prefix `ListObjectsV2` operation is valid.
2. **Bucket helper** — `/Products/Files/HttpHandlers/brimstone-megas4.ashx` returns the ASP.NET Runtime Error page before Brimstone JSON. Diagnose application/handler loading rather than S3 authentication.
3. **Existing account editor** — stock ONLYOFFICE renders Connection URL / Password / Folder title. Build a Brimstone MEGA S4 editor with Endpoint -> Access key -> Secret key -> Bucket name -> Folder title, preserving existing encrypted credentials unless deliberately replaced.

## Acceptance target

1. Connect MEGA S4 account.
2. Browse bucket/prefix tree.
3. Download arbitrary object.
4. Upload arbitrary object.
5. Open DOCX in ONLYOFFICE editor.
6. Save changes back to MEGA S4.
7. Reopen and verify remote persistence.

## Archive

Pre-cleanup experimentation is preserved at `archive/pre-v0.001-20260816`.
