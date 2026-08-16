# MEGA Cloud Connectors for ONLYOFFICE

## Brimstone MEGA S4 — v1.0.0

This is the first working V1 release of the Brimstone MEGA S4 connected-drive integration for ONLYOFFICE CommunityServer 12.8.

Everything added by this project carries a clear `BRIMSTONE` / `Brimstone` marker so custom code can be distinguished from upstream ONLYOFFICE during upgrades, support and rollback.

### Working in v1.0.0

- Connect MEGA S4 using manually entered access key and secret key.
- Pull the available S3 bucket list from MEGA S4.
- Select and connect different buckets from the same S3 account.
- Save connected-drive accounts through ONLYOFFICE's native third-party account path.
- Browse bucket and prefix trees in Files.
- Create remote folders.
- Upload files to the bucket root and subfolders.
- View and download remote files.
- Open documents in the ONLYOFFICE editor.
- Edit and save documents back to MEGA S4.
- Close and reopen documents with the saved changes still present remotely.
- Use the native precompiled ASP.NET handler route for bucket discovery.
- Restart CommunityServer without shutting down the separate external MySQL container.

The live connector DLL accepted for this release remains:

`62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f`

### Known bug — one

**Shared S3-Compatible credential import can pull buckets, but cannot currently Save the connection.**

When `Import existing S3-Compatible backup credentials` is ticked, the server-side credential import and bucket discovery work, but the client-side Save path still requires visible access-key and secret-key fields. Manual typed credentials are unaffected and Save normally.

This is the only bug listed for v1.0.0. Development of the fix continues separately from the frozen working release.

### Release safety

The pre-release working state remains frozen at:

`baseline/v0.005-99.9pct-20260816`

Commit:

`32c328654a6e266f51ab5e670be2fb224ce62a67`

Further shared-import work continues on `v0.006-shared-import`; the V1 branch is not used for experimental fixes.
