# iCloud Drive connector notes

## Goal

Expose a user's iCloud Drive as a live connected storage provider inside ONLYOFFICE Files, with normal browse/open/edit/upload/download/create-folder/rename/move/delete behaviour.

## Public API reality

Apple's public CloudKit APIs are for data stored in an app's own CloudKit containers. Apple's document-picker and File Provider APIs give apps running on Apple platforms access to user-selected files/directories, but they are not a general server-side API for an arbitrary Linux-hosted service to browse a user's whole iCloud Drive.

For a headless ONLYOFFICE Community Server integration, there is therefore no documented public Apple API equivalent to Dropbox/Google Drive that grants arbitrary iCloud Drive access to a server application.

## Preferred implementation order

1. Use documented Apple APIs if Apple exposes a suitable server-side iCloud Drive API in the future.
2. Otherwise use a narrowly-scoped iCloud web-service adapter based on the same web endpoints used by established open-source iCloud clients such as pyiCloud.
3. Keep that adapter isolated from ONLYOFFICE provider code so Apple protocol changes can be maintained without contaminating the Files DAO/provider layer.

This is still a **live-drive connector**, not a backup/sync/mount bridge. ONLYOFFICE requests file operations through the provider adapter and the adapter performs them directly against iCloud Drive.

## Authentication target

The UI should collect Apple Account credentials only for the initial authentication flow and handle Apple's 2FA/trusted-session flow. Long-lived plaintext passwords must not be stored in source, logs or browser storage. Persist only the minimum session/trust material required for reconnecting, encrypted at rest.

App-specific-password support must not be assumed until proven against the actual iCloud Drive web-service flow.

## Safety

- Never log credentials, cookies, trust tokens or download URLs.
- Keep the provider helper bound to loopback/container-private networking only.
- No generic command execution or proxy endpoint.
- Per-user provider sessions must be isolated.
- Disconnect must revoke/delete locally stored session material.
- Test rename/move/delete and conflict handling on a sacrificial iCloud account before production use.
