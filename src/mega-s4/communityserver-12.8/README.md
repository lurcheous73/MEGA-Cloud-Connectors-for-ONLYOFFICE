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

Initial source scaffold deliberately lives outside the upstream source tree. Once compilation and API behaviour are proven, the files and integration patch are applied to `module/ASC.Files.Thirdparty` by the reversible installer.
