# MEGA Cloud Connectors for ONLYOFFICE

Brimstone connected-cloud integrations for ONLYOFFICE CommunityServer 12.8.

## Current accepted release branch

The current browser-accepted release work is on:

```text
release/working-connectors-20260820
```

Target platform:

```text
onlyoffice/communityserver:12.8.0.1971
```

Pinned CommunityServer source baseline:

```text
fe1fa7babd093969e939ba6ff45a9fee1299dc93
```

This repository carries two independent user-facing cloud providers in the same custom `ASC.Files.Thirdparty.dll`:

- **Brimstone MEGA S4** — MEGA S4 object storage presented through ONLYOFFICE Files.
- **Brimstone MEGA Cloud** — normal MEGA account storage.

The shared assembly must always preserve both provider implementations. A connector-specific installer must never deploy a DLL that removes the other provider.

## MEGA S4 — accepted 20 August 2026

Browser acceptance through ONLYOFFICE Files includes:

- opening the saved connection
- bucket and folder browsing
- creating folders
- creating/writing files
- moving
- copying
- renaming
- deleting
- opening saved connection settings and pulling the live bucket list
- creating/recreating a connection from a clean Safari Private Window session

Accepted external ID namespace:

```text
sboxmega-<providerId>
sboxmega-<providerId>-<base64url-key>
```

The historical/intermediate `sbox-megas4-` namespace is forbidden.

The accepted cumulative browser overlay keeps the v1/v2/v3 layout logic, disables the legacy v3 `MutationObserver` that caused the Safari feedback loop, and uses the guarded v4.1 observer.

### Known accepted Safari limitations

A saved MEGA S4 connection is treated as **immutable** for endpoint, credentials and bucket selection. To change those values, delete and recreate the connection.

Safari can retain a stale Connected Clouds JavaScript session where an existing MEGA S4 account/settings view still opens but `Connect cloud -> MEGA S4` does not respond. A **Safari Private Window** is the proven clean-session workaround for creating/recreating the connection. Emptying Safari caches and reloading may also clear it.

Do not treat that stale-session symptom by itself as evidence that the provider/backend has failed when the existing saved connection still opens.

## Canonical S4 operator path

```bash
git pull --ff-only
sudo ./tools/brimstone-s4-install.sh status
sudo ./tools/brimstone-s4-install.sh verify
sudo ./tools/brimstone-s4-install.sh install
```

The canonical S4 installer:

- builds the shared S4 + MEGA Cloud DLL from pinned CommunityServer source;
- validates both providers and the accepted S4 ID namespace;
- protects the external `onlyoffice-mysql-server` from CommunityServer shutdown calls;
- backs up connector runtime files before mutation;
- installs the browser-accepted S4 handler topology and UI overlay;
- restarts only CommunityServer;
- verifies MySQL did not restart or change `StartedAt`;
- records rollback state.

See:

- `docs/INSTALL-S4.md`
- `docs/MEGA-S4-ACCEPTED-2026-08-20.md`
- `docs/BRIMSTONE-COMBINED-INSTALL.md`

## Release architecture

The production model is **one repository / one Git update / two connector front-ends / one shared DLL engine**.

MEGA S4 is the first canonical production front-end. MEGA Cloud remains in the shared assembly and its separate production front-end is promoted when its runtime packaging is complete.

Historical versioned documents and branches remain in the repository as development evidence. They should not be read as the current production state unless explicitly marked as the accepted 20 August 2026 release.

All project-specific source, runtime markers, tooling and documentation retain an obvious `BRIMSTONE` / `Brimstone` identity so custom code remains distinguishable from upstream ONLYOFFICE code.
