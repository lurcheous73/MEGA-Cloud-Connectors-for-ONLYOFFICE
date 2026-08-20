# Brimstone MEGA S4 — canonical installer

This document describes the browser-accepted Brimstone MEGA S4 release for ONLYOFFICE CommunityServer 12.8.0.1971.

## Supported platform

The installer is deliberately fail-closed against the exact CommunityServer image used for acceptance:

```text
onlyoffice/communityserver:12.8.0.1971
```

The shared connector DLL is built from pinned CommunityServer source commit:

```text
fe1fa7babd093969e939ba6ff45a9fee1299dc93
```

The build contains both custom providers in the same `ASC.Files.Thirdparty.dll`:

- Brimstone MEGA S4
- Brimstone MEGA Cloud

This is intentional. Installing or upgrading S4 must never remove the MEGA Cloud provider from the shared assembly.

## Operator flow

Clone or update this repository, then run:

```bash
git pull --ff-only
sudo ./tools/brimstone-s4-install.sh status
sudo ./tools/brimstone-s4-install.sh verify
sudo ./tools/brimstone-s4-install.sh install
```

Rollback the last canonical S4 installation with:

```bash
sudo ./tools/brimstone-s4-install.sh rollback
```

The installer is idempotent: if the exact built DLL and all accepted runtime contracts are already installed, `install` reports that no change is required.

## What `install` does

1. Requires a clean connector repository.
2. Verifies the exact supported CommunityServer image.
3. Builds a fresh combined S4 + MEGA Cloud `ASC.Files.Thirdparty.dll` from pinned source.
4. Rejects any candidate containing the obsolete `sbox-megas4-` namespace.
5. Requires the accepted browser namespace `sboxmega-`.
6. Backs up the current connector DLL, S4 handler and all S4-patched UI runtime files.
7. Ensures CommunityServer cannot shut down the external `onlyoffice-mysql-server` during restart.
8. Installs the combined connector DLL.
9. Installs the precompiled Brimstone MEGA S4 handler metadata.
10. Installs the exact browser-accepted cumulative S4 UI overlay.
11. Rebuilds existing `.gz` UI copies deterministically with `gzip -n`.
12. Restarts only `onlyoffice-community-server`.
13. Waits for CommunityServer warmup to complete.
14. Verifies that the external MySQL container did not restart or change `StartedAt`.
15. Verifies the DLL, handler, UI and route contracts.
16. Records the backup directory and installed release state for rollback.

If installation fails after runtime mutation begins, the connector runtime is restored automatically from the pre-install backup.

## External MySQL safety

CommunityServer 12.8's startup script contains two plain `mysqladmin shutdown` calls. With `root.cnf` targeting the external MySQL container, those calls can shut down the external database during a CommunityServer restart.

The Brimstone safety patch changes only those exact two calls to local-socket-only commands:

```text
mysqladmin --no-defaults --protocol=socket --socket=/var/run/mysqld/mysqld.sock shutdown || true
```

This protection is a platform safety invariant. S4 rollback intentionally **does not** restore the vulnerable shutdown commands.

## Accepted S4 ID contract

The browser-tested namespace is:

```text
sboxmega-<providerId>
sboxmega-<providerId>-<base64url-key>
```

The following historical/intermediate namespace is forbidden:

```text
sbox-megas4-
```

The canonical builder checks both conditions before a DLL can be installed.

## Safari UI regression guard

The accepted S4 UI is cumulative:

- v1
- v2
- v3 field-layout normaliser
- legacy v3 `MutationObserver` disabled
- v4.1 guarded observer active

The old v3 observer created a Safari mutation feedback loop because `normaliseMegaS4Form()` re-appended credential rows while observing `childList` mutations. The accepted release retains the v3 layout logic but disables only that observer. v4.1 owns guarded observation via `queueNormalise`.

The exact accepted overlay is stored at:

```text
src/mega-s4/communityserver-12.8/ui/mega-s4-thirdparty-accepted.js
```

Accepted overlay SHA-256:

```text
ee90cfbd7e6ed94008e555e501bde917b39677c49da8a47924112c614888f967
```

## Browser acceptance completed 20 August 2026

The accepted release was tested through the ONLYOFFICE Files UI for:

- opening the saved MEGA S4 connection
- browsing bucket/folder content
- creating folders
- creating/writing files
- moving
- copying
- renaming
- deleting

The accepted live combined DLL during that test had SHA-256:

```text
aa5ffeb00446c44eefaf48d91d045271cbf62405fb8753024a10bb7c8bf84226
```

A rebuild is validated by embedded runtime contracts rather than relying solely on reproducing that historical binary hash.

## Backups and state

Runtime backups are written beneath:

```text
/var/backups/mega-cloud-connectors-for-onlyoffice/
```

Canonical S4 installer state is written beneath:

```text
/var/lib/brimstone-connectors/
```

Existing ONLYOFFICE third-party account/database rows are not deleted or recreated by this installer.
