# ONLYOFFICE 12.8 connected-storage provider contract

Discovery target: ONLYOFFICE Community Server `fe1fa7babd093969e939ba6ff45a9fee1299dc93` (12.8 baseline used by this project).

## Executive finding

ONLYOFFICE's live connected-storage support is already a provider/DAO architecture. We do **not** need to fake MEGA as WebDAV, FUSE, a mounted filesystem, or a sync target.

`Global` resolves `ASC.Files.Core.IDaoFactory` through the `files` Autofac container. In stock 12.8 that service is:

```text
ASC.Files.Thirdparty.ProviderDao.ProviderDaoFactory, ASC.Files.Thirdparty
```

The factory returns composite `IFileDao`, `IFolderDao`, `ISecurityDao`, `ITagDao`, and `IProviderDao` implementations. The composite DAOs choose a provider-specific DAO by examining the entry ID. That is the insertion point for MEGA Cloud and MEGA S4.

## Exact upstream source points

### Files DAO contract

- `web/studio/ASC.Web.Studio/Products/Files/Core/Dao/Interfaces/IDaoFactory.cs`
- `web/studio/ASC.Web.Studio/Products/Files/Core/Dao/Interfaces/IFileDao.cs`
- `web/studio/ASC.Web.Studio/Products/Files/Core/Dao/Interfaces/IFolderDao.cs`
- `web/studio/ASC.Web.Studio/Products/Files/Core/Dao/Interfaces/IProviderDao.cs`
- `web/studio/ASC.Web.Studio/Products/Files/Core/Dao/Interfaces/IProviderInfo.cs`

`IDaoFactory` exposes five DAO families: file, folder, tag, security and provider-account metadata.

`IProviderInfo` supplies the connected-drive identity and root:

```text
ID
ProviderKey
Owner
RootFolderType
CreateOn
CustomerTitle
RootFolderId
CheckAccess()
InvalidateStorage()
```

### Runtime composition

`web/studio/ASC.Web.Studio/Products/Files/Helpers/Global.cs` loads the `files` Autofac container through `DIHelper` and resolves `IDaoFactory`.

`web/studio/ASC.Web.Studio/web.autofac.config` registers:

```xml
<component
  type="ASC.Files.Thirdparty.ProviderDao.ProviderDaoFactory, ASC.Files.Thirdparty"
  service="ASC.Files.Core.IDaoFactory, ASC.Web.Files"
  instance-scope="single-instance" />
```

### Third-party provider implementation

The implementation lives in `module/ASC.Files.Thirdparty`.

Core composition files:

- `ProviderDao/ProviderDaoFactory.cs`
- `ProviderDao/ProviderDaoBase.cs`
- `ProviderDao/ProviderFileDao.cs`
- `ProviderDao/ProviderFolderDao.cs`
- `ProviderDao/ProviderSecutiryDao.cs` (upstream spelling)
- `ProviderDao/ProviderTagDao.cs`
- `ProviderAccountDao.cs`
- `IDaoSelector.cs`
- `RegexDaoSelectorBase.cs`

`ProviderDaoBase` has a static selector list. Stock 12.8 registers:

```text
DbDaoSelector
SharpBoxDaoSelector
SharePointDaoSelector
GoogleDriveDaoSelector
BoxDaoSelector
DropboxDaoSelector
OneDriveDaoSelector
```

Each provider selector owns an entry-ID namespace and returns provider-specific implementations of the standard Files DAOs.

Dropbox is a particularly clean reference implementation:

- `Dropbox/DropboxDaoSelector.cs`
- `Dropbox/DropboxProviderInfo.cs`
- `Dropbox/DropboxStorage.cs`
- `Dropbox/DropboxDaoBase.cs`
- `Dropbox/DropboxFileDao.cs`
- `Dropbox/DropboxFolderDao.cs`
- `Dropbox/DropboxSecurityDao.cs`
- `Dropbox/DropboxTagDao.cs`

Its IDs are provider-qualified, for example:

```text
dropbox-<linkId>
dropbox-<linkId>-<provider path encoded with | separators>
```

The selector turns the qualified ONLYOFFICE ID back into the provider-native path and chooses the matching DAO.

## Connected-account persistence

`ProviderAccountDao.cs` stores connected accounts in `files_thirdparty_account`.

The stock row includes:

```text
id
provider
customer_title
user_name
password
token
user_id
folder_type
create_on
url
```

Passwords/tokens are encrypted with ONLYOFFICE `InstanceCrypto` before they are persisted. OAuth providers normally retain encrypted token/session material rather than a user's raw login password.

The stock provider enum is closed, so adding a first-class provider requires extending `ProviderTypes` and `ToProviderInfo()`.

For MEGA Cloud we should persist a resumable MEGA session token after authentication and avoid retaining the account password once the session exists.

For MEGA S4 the access/secret key pair is long-lived provider credential material; it should be stored through the same encrypted server-side mechanism, never JavaScript local storage or Git/config plaintext.

## Files UI behaviour

`EntryManager.GetThirpartyFolders()` obtains connected accounts from `Global.DaoFactory.GetProviderDao()`, converts each `IProviderInfo` root to a normal Files folder entry, and lets the standard Files service work through the provider DAOs.

This is why a native provider behaves as a **live drive**: document open, download, upload/save, folder navigation, move/copy/delete and other Files operations continue through the normal Files service and DAO contract rather than through a separate sync subsystem.

## MEGA S4 integration surface

Add provider key `MegaS4`.

Suggested ONLYOFFICE ID namespace:

```text
megas4-<linkId>
megas4-<linkId>-<encoded object/prefix key>
```

A connected S4 account should represent one selected bucket as the root of one connected drive. This gives users a normal Files tree instead of exposing the S3 account/bucket hierarchy as implementation detail.

Mapping:

```text
ONLYOFFICE root folder -> selected S4 bucket
folder                  -> object prefix ending in /
file                    -> S3 object
file read               -> GetObject stream
file create/replace     -> PutObject or multipart upload
folder create           -> zero-byte prefix marker where useful
move/rename file        -> CopyObject, verify destination, DeleteObject source
move/rename folder      -> enumerate prefix, copy+verify all, then delete originals
file/folder delete      -> DeleteObject(s)
metadata                -> ListObjectsV2 / HeadObject
```

MEGA S4 compatibility baseline:

```text
region:          g
endpoint:        https://s3.g.megas4.com
path style:      true
TLS:             true
SigV4:           required
```

Community Server 12.8 already uses `AWSSDK.S3` 4.x elsewhere in-tree; the connector should use that SDK generation instead of adding a second S3 implementation.

## MEGA Cloud integration surface

Add provider key `MegaCloud`.

Suggested ONLYOFFICE ID namespace:

```text
megacloud-<linkId>
megacloud-<linkId>-<node handle>
```

Unlike path-based services, MEGA nodes have stable handles. The DAO selector should preserve the link ID separately from the MEGA node handle and let the provider API resolve parent/child relationships.

Use the official `meganz/sdk` public API. Desired auth lifecycle:

1. user enters MEGA account email/password;
2. complete MFA if required;
3. obtain/export resumable session material;
4. encrypt and persist the session server-side;
5. discard plaintext password;
6. resume future sessions from session material.

If direct C# interop is practical, expose a small C ABI around the C++ SDK and use P/Invoke. If the asynchronous SDK makes that unsafe or excessively brittle, an isolated localhost-only SDK helper is acceptable, but it must expose provider operations (login/list/read/write/move/delete), **not** a filesystem mount or WebDAV facade.

## Source changes expected for each new provider

1. Add provider key to `ProviderAccountDao.ProviderTypes`.
2. Add `ToProviderInfo()` construction for the provider.
3. Add provider namespace to `ProviderDaoBase.Selectors`.
4. Add provider selector.
5. Add provider info/session object.
6. Add provider storage/API client.
7. Add provider file DAO.
8. Add provider folder DAO.
9. Add provider security/tag DAOs following the existing connected-storage policy.
10. Add project compile items and required package/native references.
11. Enable the provider in `ThirdpartyConfiguration` / Files UI.
12. Add connection-dialog handling and provider icon/text.

## Implementation order locked for Phase 1

1. MEGA S4 provider — quickest way to prove a new native selector/DAO end to end.
2. MEGA Cloud — reuse the proven ONLYOFFICE-side provider surface and swap in the official MEGA SDK.
3. Only after both work: hardening, installer/status/rollback and upstream-ready source diffs.
4. iCloud Drive remains Phase 2.

## Non-goals

- no rclone
- no FUSE
- no WebDAV translation layer
- no local mirror
- no pretending a backup destination is a connected drive
- no plaintext cloud secrets in source, logs or browser persistence

The user experience must remain a normal, live ONLYOFFICE connected drive.
