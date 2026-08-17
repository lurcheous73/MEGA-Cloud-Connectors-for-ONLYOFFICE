# MEGA S4 live connected-drive provider — Community Server 12.8

This directory contains the source-level implementation for a native ONLYOFFICE Files provider backed directly by MEGA S4.

Design target:

```text
ONLYOFFICE Files
    -> ASC.Files.Thirdparty provider/DAO layer
    -> AWSSDK.S3 4.0.19.2
    -> MEGA S4 (SigV4, region g, path-style endpoint)
```

This is a **live connected drive**, not backup, sync, FUSE, WebDAV, or a mounted filesystem.

The implementation is developed against Community Server commit `fe1fa7babd093969e939ba6ff45a9fee1299dc93`.

Provider key: `MegaS4`

Entry-ID namespace:

```text
megas4-<linkId>
megas4-<linkId>-<base64url UTF-8 S3 key>
```

One connected provider row represents one selected S4 bucket. Prefixes ending `/` are folders; objects are files.

## Implemented in the first source pass

- collision-safe provider IDs for arbitrary UTF-8 object keys;
- encrypted account-token payload for bucket/region/path-style settings;
- direct `AmazonS3Client` custom-endpoint connection;
- paginated immediate-child folder/file listing;
- metadata and range downloads;
- file create/replace/delete;
- persistent empty folders using zero-byte prefix markers;
- verified file copy/move, including multipart copy for objects >= 5 GiB;
- recursive folder copy/move with copy-before-delete failure protection;
- multipart uploads for ONLYOFFICE chunked upload sessions;
- native `IFileDao`, `IFolderDao`, `ISecurityDao` and `ITagDao` implementations;
- provider selector and `IProviderInfo` implementation;
- source integration patch for `ProviderAccountDao`, `ProviderDaoBase` and `ASC.Files.Thirdparty.csproj`.

## Still required before installation

1. Add the MEGA S4 connection UI: endpoint/access/secret -> fetch buckets -> select bucket -> validate -> connect.
2. Wire the provider into Files third-party enablement/resources/icons.
3. Apply the integration patch to an exact 12.8 source checkout and compile `ASC.Files.Thirdparty`.
4. Resolve any compile/API-generation differences against `AWSSDK.S3` 4.0.19.2.
5. Run a disposable-bucket live-drive acceptance test before touching a production Workspace.
6. Wrap the proven source changes in install/status/rollback tooling.

The source is intentionally **not installed yet**.
