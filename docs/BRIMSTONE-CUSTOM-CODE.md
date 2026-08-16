# BRIMSTONE custom-code convention

All custom ONLYOFFICE work maintained in these repositories must carry the literal marker `BRIMSTONE` somewhere in the code path that implements or deploys it. The marker is intentional: it gives us a reliable grep target that distinguishes our work from upstream ONLYOFFICE code during upgrades, incident response and rollback.

## Naming

- C# helper/bridge types added by us use a `Brimstone...` name where practical.
- JavaScript overlays and deployment scripts include a `BRIMSTONE` marker string.
- When an upstream source file must be patched, the injected block should include a `BRIMSTONE CUSTOM CODE` comment.

## Shared secrets

For tenant-scoped administrator/service credentials, prefer ONLYOFFICE `CoreContext.Configuration.SaveSetting()` / `GetSetting()` rather than direct SQL. The values are encrypted by ONLYOFFICE before they are persisted in `core_settings`.

Keys owned directly by our integrations should use the prefix:

`Brimstone.Secret.`

Examples:

- `Brimstone.Secret.MegaS4.Primary`
- `Brimstone.Secret.MegaCloud.Primary`
- `Brimstone.Secret.iCloud.Primary`

Native ONLYOFFICE consumer credentials (for example the existing `S3Compatible` AuthorizationKeys consumer) remain in their native key names and are read through `ConsumerFactory`, not copied with SQL.

## Connected-drive credentials

`core_settings` is the canonical shared/admin secret store. A user-visible connected drive remains represented by the native `files_thirdparty_account` record.

When a connected drive imports shared credentials, the import is a one-time server-side copy: the real credentials are resolved on the server and the connected-drive account receives its own encrypted snapshot. Later rotation of the shared/backup credential set must not silently change an existing connected drive.

## No direct secret SQL writes

Do not write plaintext or pre-encrypted secret material directly into `core_settings` or `files_thirdparty_account`. Use the corresponding ONLYOFFICE configuration/provider APIs so tenant scoping, crypto and cache invalidation remain native.
