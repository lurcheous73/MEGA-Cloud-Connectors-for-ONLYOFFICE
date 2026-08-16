# MEGA Cloud Connectors for ONLYOFFICE

First-class live cloud-storage connectors for ONLYOFFICE Community Server / Workspace.

This project is intentionally separate from `ONLYOFFICE-Community-Storage-Profiles`: that project handles backend/static storage, backup and restore. This repository is for user-facing **Files → Connect cloud storage** integrations.

## Phase 1 priorities

### MEGA Cloud

A live connector for normal `mega.nz` cloud storage, intended to sit alongside the existing Dropbox / Nextcloud / ownCloud-style connected storage providers in ONLYOFFICE Files.

Target capabilities:

- direct MEGA SDK/API integration rather than a mounted-filesystem bridge
- end-user account login, MFA and resumable session handling
- browse folders and files
- upload and download
- create folders
- rename, move and delete
- expose file metadata needed by ONLYOFFICE
- open supported documents through the normal ONLYOFFICE document workflow
- reconnect / disconnect cleanly

### iCloud Drive

A live connector for a user's iCloud Drive.

Apple does not currently document a general headless/server-side API equivalent to Dropbox/Google Drive for browsing an arbitrary user's complete iCloud Drive. Public Apple APIs are primarily app-container or Apple-device document/file-provider APIs. Therefore the preferred order is:

1. use a documented Apple server-side interface if one becomes available;
2. otherwise isolate the minimum required iCloud web-service protocol behind a narrow provider adapter.

The adapter remains a direct live-drive integration: it is **not** rclone, FUSE, WebDAV translation or a local mirror.

Target capabilities:

- Apple Account authentication, 2FA and trusted-session handling
- root and nested-folder browsing
- file metadata and streamed downloads
- upload / replace
- create folders
- rename / move / delete
- normal ONLYOFFICE open/edit/save workflow
- reconnect / disconnect with encrypted local session material only

See `docs/icloud-drive.md`.

## Phase 2

### MEGA S4

A connector for MEGA S4 object storage, using the S3-compatible API but presented as a normal connected cloud-storage source inside ONLYOFFICE Files.

Target capabilities:

- endpoint / region configuration
- saved access and secret keys via the appropriate ONLYOFFICE credential store
- list/select buckets
- browse object prefixes as folders
- upload/download objects
- create prefixes/folders where appropriate
- rename/move through safe copy/delete semantics
- delete objects
- path-style support for MEGA S4

Google Drive and Dropbox already exist in ONLYOFFICE. Polishing those integrations is lower priority than adding MEGA Cloud and iCloud Drive.

## Development approach

1. Map the current ONLYOFFICE connected-storage provider/DAO contract.
2. Implement MEGA Cloud against the official MEGA SDK/API.
3. Map Apple's supported iCloud interfaces and isolate any unavoidable iCloud web-service compatibility layer.
4. Keep secrets out of Git, logs and browser persistence.
5. Provide reversible installer, status and rollback tooling for supported Community Server builds.
6. Test on a disposable instance before production deployment.

## Design rule

These are **live drives**, not backup targets or sync mounts. Do not insert rclone, FUSE, WebDAV or mounted-filesystem translation layers simply to avoid implementing the ONLYOFFICE provider contract. Use native provider APIs/SDKs wherever practical. A helper process is acceptable only where the provider cannot safely or practically be integrated in-process, and it must expose a narrow provider API rather than a filesystem bridge.

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

Early development / interface discovery.

## Support the work

If this project saves you time or helps keep ONLYOFFICE Community useful, you can support the work here:

**Buy Me a Coffee:** https://buymeacoffee.com/chrisswain

## Licence

Apache License 2.0. See `LICENSE`.
