# Priority scope

## Phase 1 — live cloud drives

The first implementation targets are:

1. **MEGA Cloud** — direct live integration using the official MEGA SDK/API where practical.
2. **iCloud Drive** — direct live integration. Use documented Apple APIs if a suitable server-side interface exists; otherwise isolate the required iCloud web-service protocol behind a narrow provider adapter.

Both must behave as normal ONLYOFFICE connected drives: browse, open, edit, upload, download, create folders, rename, move and delete. They are not backup, sync or mounted-drive features.

## Phase 2

MEGA S4 remains useful as a connected object-storage provider and will follow the live-drive work.

Google Drive and Dropbox already exist in ONLYOFFICE. They may be polished later, but they are not the current priority.

## Design rule

Do not insert WebDAV/rclone/FUSE/mounted-filesystem translation layers merely to avoid implementing the provider contract. Use each provider's native API/SDK for live-drive operations whenever possible. A helper process is acceptable only when a provider cannot be safely or practically integrated in-process, and it must remain an API adapter rather than a filesystem bridge.
