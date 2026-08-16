# MEGA Cloud Connectors for ONLYOFFICE

First-class MEGA storage connectors for ONLYOFFICE Community Server / Workspace.

This project is intentionally separate from `ONLYOFFICE-Community-Storage-Profiles`: that project handles backend/static storage, backup and restore. This repository is for user-facing **Files → Connect cloud storage** integrations.

## Planned connectors

### MEGA Cloud

A connector for normal `mega.nz` cloud storage, intended to sit alongside the existing Dropbox / Nextcloud / ownCloud-style connected storage providers in ONLYOFFICE Files.

Target capabilities:

- authenticate to a MEGA account without storing credentials in source code
- browse folders and files
- upload and download
- create folders
- rename, move and delete
- expose file metadata needed by ONLYOFFICE
- open supported documents through the normal ONLYOFFICE document workflow
- reconnect / disconnect cleanly

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

## Development approach

1. Map the current ONLYOFFICE Dropbox / Nextcloud / ownCloud connector interfaces and request flow.
2. Map the official MEGA Cloud API and MEGA S4 S3-compatible behaviour.
3. Build each connector behind its own provider module.
4. Keep secrets out of Git, logs and browser persistence.
5. Provide reversible installer, status and rollback tooling for supported Community Server builds.
6. Test on a disposable instance before any production deployment.

## Repository layout

```text
src/
  mega-cloud/
  mega-s4/
patches/
scripts/
tests/
docs/
```

The implementation will be developed in feature branches and promoted to `main` only after the connector paths are tested.

## Status

Early development / interface discovery.

## Support the work

If this project saves you time or helps keep ONLYOFFICE Community useful, you can support the work here:

**Buy Me a Coffee:** https://buymeacoffee.com/chrisswain

## Licence

Apache License 2.0. See `LICENSE`.
