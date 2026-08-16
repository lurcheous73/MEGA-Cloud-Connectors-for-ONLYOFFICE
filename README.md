# MEGA Cloud Connectors for ONLYOFFICE

First-class live cloud-storage connectors for ONLYOFFICE Community Server / Workspace.

This project is intentionally separate from `ONLYOFFICE-Community-Storage-Profiles`: that project handles backend/static storage, backup and restore. This repository is for user-facing **Files → Connect cloud storage** integrations.

## Phase 1 priorities — MEGA first

Phase 1 deliberately concentrates on both MEGA storage families so the ONLYOFFICE provider contract is proven against two direct, live APIs before we tackle iCloud compatibility work.

### MEGA Cloud

A live connector for normal `mega.nz` cloud storage, intended to sit alongside the existing Dropbox / Nextcloud / ownCloud-style connected storage providers in ONLYOFFICE Files.

Implementation direction:

- use the official MEGA C++ SDK / public API directly;
- no rclone, FUSE, WebDAV translation or local mirror;
- end-user login with email/password, MFA when enabled, and resumable MEGA sessions;
- isolate SDK language interop behind the smallest practical local provider service or C ABI wrapper if direct C# interop is not maintainable;
- the interop layer exposes provider operations, never a filesystem mount.

Target capabilities:

- connect/disconnect a MEGA account;
- root and nested-folder browsing;
- file/folder metadata;
- upload and streamed download;
- create folders;
- rename, move and delete;
- open supported documents through the normal ONLYOFFICE document workflow;
- save edited documents back to MEGA;
- large-file handling;
- restart/session persistence without retaining the user's plaintext password.

Official implementation reference: `meganz/sdk`.

### MEGA S4

A live connector for MEGA S4 object storage, using its S3-compatible API but presented as a normal connected cloud-storage source inside ONLYOFFICE Files.

Implementation direction:

- direct S3-compatible API calls from the provider layer;
- reuse the proven MEGA S4 endpoint/signing/addressing knowledge from the Community Storage Profiles work without coupling this connector to backup/static-storage code;
- use path-style addressing where required;
- represent prefixes as folders in the ONLYOFFICE Files UI;
- do not treat S4 as a backup target here — this is a live connected drive.

Target capabilities:

- endpoint / signing-region configuration;
- saved access and secret keys via an appropriate encrypted ONLYOFFICE/provider credential store;
- list/select buckets;
- browse prefixes as folders;
- upload/download objects;
- create folder-prefix placeholders where appropriate;
- rename/move through safe copy/delete semantics;
- delete objects;
- pagination;
- large-object and multipart handling;
- restart persistence;
- normal ONLYOFFICE open/edit/save workflow.

Official protocol reference: `meganz/s4-specs`.

## Phase 2 — iCloud Drive

A live connector for a user's iCloud Drive.

Apple does not currently document a general headless/server-side API equivalent to Dropbox/Google Drive for browsing an arbitrary user's complete iCloud Drive. Public Apple APIs are primarily app-container or Apple-device document/file-provider APIs. Therefore the preferred order is:

1. use a documented Apple server-side interface if one becomes available;
2. otherwise isolate the minimum required iCloud web-service protocol behind a narrow provider adapter.

The adapter remains a direct live-drive integration: it is **not** rclone, FUSE, WebDAV translation or a local mirror.

Target capabilities:

- Apple Account authentication, 2FA and trusted-session handling;
- root and nested-folder browsing;
- file metadata and streamed downloads;
- upload / replace;
- create folders;
- rename / move / delete;
- normal ONLYOFFICE open/edit/save workflow;
- reconnect / disconnect with encrypted local session material only.

See `docs/icloud-drive.md`.

Google Drive and Dropbox already exist in ONLYOFFICE. Polishing those integrations is lower priority than MEGA Cloud, MEGA S4 and iCloud Drive.

## Development approach

1. Map the current ONLYOFFICE connected-storage provider/DAO contract.
2. Build the common ONLYOFFICE provider integration surface once.
3. Implement MEGA Cloud against the official MEGA SDK/API.
4. Implement MEGA S4 against the direct S3-compatible API.
5. Prove open/edit/save, upload/download and CRUD against both live MEGA backends.
6. Then tackle iCloud Drive and isolate any unavoidable Apple web-service compatibility layer.
7. Keep secrets out of Git, logs and browser persistence.
8. Provide reversible installer, status and rollback tooling for supported Community Server builds.
9. Test on a disposable instance before production deployment.

## Design rule

These are **live drives**, not backup targets or sync mounts. Do not insert rclone, FUSE, WebDAV or mounted-filesystem translation layers simply to avoid implementing the ONLYOFFICE provider contract. Use native provider APIs/SDKs wherever practical. A helper process is acceptable only where language/runtime boundaries make it materially safer or cleaner, and it must expose a narrow provider API rather than a filesystem bridge.

## Repository layout

```text
src/
  mega-cloud/
  mega-s4/
  icloud-drive/
patches/
scripts/
tests/
docs/
```

The implementation is developed in feature branches and promoted to `main` only after the connector paths are tested.

## Status

Early development / interface discovery. Phase 1 is MEGA Cloud + MEGA S4.

## Support the work

If this project saves you time or helps keep ONLYOFFICE Community useful, you can support the work here:

**Buy Me a Coffee:** https://buymeacoffee.com/chrisswain

## Licence

Apache License 2.0. See `LICENSE`.
