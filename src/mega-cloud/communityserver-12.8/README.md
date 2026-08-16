# MEGA Cloud live connected-drive provider — Community Server 12.8

Phase 1 companion to the MEGA S4 provider.

The user-facing drive talks directly to the official `meganz/sdk`. It is not implemented through rclone, FUSE, WebDAV, a local mirror, or sync staging.

Target architecture:

```text
ONLYOFFICE Files
    -> ASC.Files.Thirdparty MegaCloud DAO
    -> small C ABI / PInvoke adapter
    -> official MEGA C++ SDK
    -> mega.nz live account
```

The MEGA SDK is asynchronous and does not ship a ready-made C# binding in the current source tree, so this project keeps the interop boundary deliberately narrow. ONLYOFFICE sees normal provider operations; the native shim owns SDK listeners/callbacks and returns stable result objects to managed code.

Authentication lifecycle:

1. user enters MEGA account email/password;
2. native SDK login is performed, including MFA when required;
3. the SDK's resumable session is exported;
4. ONLYOFFICE stores only that session material through its encrypted `files_thirdparty_account.token` field;
5. plaintext account password is discarded;
6. subsequent starts use fast/session login.

Provider key: `MegaCloud`

Entry IDs use the connected-provider link ID plus the stable MEGA node handle, never a filesystem path:

```text
megacloud-<linkId>
megacloud-<linkId>-<base64url-node-handle>
```

Initial work in this branch defines the native ABI and managed interop contract. The full DAO will reuse the ONLYOFFICE provider surface proven by the MEGA S4 implementation.
