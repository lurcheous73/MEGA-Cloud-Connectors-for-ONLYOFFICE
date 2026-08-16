# Architecture

## Goal

Provide two independent first-class cloud-storage connectors for ONLYOFFICE Files:

1. **MEGA Cloud** — normal MEGA account storage.
2. **MEGA S4** — MEGA's S3-compatible object storage exposed as connected cloud storage.

These connectors are deliberately separate from backend/static storage and backup/restore integrations.

## Design rules

- Preserve existing ONLYOFFICE Dropbox, Nextcloud, ownCloud and other providers.
- Add new provider identities rather than repurposing an existing provider.
- Keep provider secrets out of Git, logs and browser persistence.
- Prefer ONLYOFFICE's native third-party storage abstractions and APIs over direct database changes.
- Treat install, status and rollback as first-class operations.
- Refuse unsupported ONLYOFFICE builds instead of patching blindly.
- Develop and test each provider independently.

## MEGA Cloud path

The discovery phase will map the current ONLYOFFICE connected-storage provider contract against the official MEGA Cloud API.

Expected adapter responsibilities include:

- authentication/session lifecycle
- folder tree enumeration
- file metadata translation
- ranged or streaming download where supported
- upload
- create folder
- rename/move/delete
- reconnect/disconnect
- handling large files and transient failures

No implementation decision about credentials or session persistence is considered final until the current ONLYOFFICE provider code and MEGA authentication model have been mapped.

## MEGA S4 path

MEGA S4 will use S3-compatible semantics but present prefixes and objects through the ONLYOFFICE connected-storage model.

Expected adapter responsibilities include:

- endpoint and signing-region configuration
- path-style addressing where required
- saved access/secret credentials
- bucket discovery and selection
- prefix-as-folder mapping
- object listing
- upload/download
- copy/delete based rename and move
- safe deletion
- pagination and large-object handling

## Compatibility baseline

Initial development targets the same lab baseline used by the companion Community Storage Profiles work:

- ONLYOFFICE Workspace Community Server 12.8.x
- ONLYOFFICE Control Panel 3.5.5.x

Exact build/hash preflights will be added before runtime installers are considered usable.

## Repository boundaries

`ONLYOFFICE-Community-Storage-Profiles` remains responsible for backend/static object storage, backup and restore.

This repository owns only user-facing connected-cloud-storage integrations shown from the Files product.
