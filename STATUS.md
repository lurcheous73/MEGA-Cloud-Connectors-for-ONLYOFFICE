# BRIMSTONE MEGA S4 v0.003 status

Baseline date: 2026-08-16
Upstream CommunityServer baseline: `ONLYOFFICE/CommunityServer@fe1fa7babd093969e939ba6ff45a9fee1299dc93`

## External MEGA S4 transport — PROVEN

Using burnable test credentials and an independently constructed SigV4 request:

- `GET https://s3.g.megas4.com/` -> HTTP 200 `ListAllMyBucketsResult`.
- `GET https://s3.g.megas4.com/onlyoffice?list-type=2&max-keys=5` -> HTTP 200 `ListBucketResult`.
- The Amsterdam endpoint also returned HTTP 200, but the connector baseline remains the global `g` endpoint and signing region `g`.

## v0.003 live candidate — PROVEN

Live `ASC.Files.Thirdparty.dll` SHA256:

`62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f`

The provider ID namespace remains:

- root: `sboxmega-<providerId>`
- object/folder: `sboxmega-<providerId>-<base64url-key>`

v0.003 adds Dropbox-style external-ID restoration across `ChunkedUploadSession` boundaries so ONLYOFFICE continues routing subsequent upload requests back to the MEGA S4 DAO.

## ONLYOFFICE integration — PROVEN

- Manual credentials plus a manually entered bucket name save successfully.
- Provider Save persists a MEGA S4 account.
- The saved MEGA S4 root opens normally in Files.
- Bucket/prefix browsing works.
- A folder named `test` created in ONLYOFFICE appeared in the real MEGA S4 `onlyoffice` bucket.
- Arbitrary image files uploaded through ONLYOFFICE are written successfully to the MEGA S4 root.
- Arbitrary image files uploaded through ONLYOFFICE are written successfully inside the `test` subfolder.
- Uploaded MEGA S4 objects open successfully in ONLYOFFICE view mode.
- Uploaded MEGA S4 objects download successfully through ONLYOFFICE.
- The earlier `Can not convert id:` upload failure is fixed by restoring external `sboxmega-*` IDs before an upload session leaves the provider DAO and between non-final chunks.
- The existing MEGA account survives the v0.002 -> v0.003 DLL deployment unchanged.
- Provider Delete has previously been proven.
- `CheckAccess()` validates the selected bucket using `ListObjectsV2` before persistence.

## Known remaining bugs

1. **Bucket helper** — `Pull buckets` still fails because `/Products/Files/HttpHandlers/brimstone-megas4.ashx` returns the ASP.NET Runtime Error page before Brimstone JSON. Manual bucket entry remains functional.
2. **Existing account editor** — existing MEGA accounts still need a proper Brimstone editor rather than the stock Connection URL / Password / Folder title form.
3. **Shared credential import UX** — server-side import is retained, but bucket discovery through the broken helper is not yet usable. Test Save separately from bucket discovery before declaring this path complete.

## Acceptance progress

1. Connect MEGA S4 account — PASS (manual credentials/manual bucket).
2. Browse bucket/prefix tree — PASS.
3. Create remote folder from ONLYOFFICE — PASS.
4. Upload arbitrary object to bucket root — PASS.
5. Upload arbitrary object to subfolder — PASS.
6. View arbitrary object through ONLYOFFICE — PASS.
7. Download arbitrary object through ONLYOFFICE — PASS.
8. Open DOCX in ONLYOFFICE editor — NEXT.
9. Save changes back to MEGA S4 — NEXT.
10. Reopen and verify remote persistence — NEXT.

## Archive

Pre-cleanup experimentation is preserved at `archive/pre-v0.001-20260816`.
