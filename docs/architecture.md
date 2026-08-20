# Architecture

## Goal

Provide two independent first-class cloud-storage connectors for ONLYOFFICE Files:

1. **Brimstone MEGA Cloud** — normal MEGA account storage.
2. **Brimstone MEGA S4** — MEGA's S3-compatible object storage exposed as connected cloud storage.

These connectors are deliberately separate from backend/static storage and backup/restore integrations.

## Design rules

- Preserve existing ONLYOFFICE Dropbox, Nextcloud, ownCloud and other providers.
- Add new provider identities rather than repurposing an existing provider.
- Keep provider secrets out of Git, logs and browser persistence.
- Prefer ONLYOFFICE's native third-party storage abstractions and APIs over direct database changes.
- Treat install, status, verify and rollback as first-class operations.
- Refuse unsupported ONLYOFFICE builds instead of patching blindly.
- Develop and browser-test each provider independently.
- Preserve both Brimstone providers whenever the shared `ASC.Files.Thirdparty.dll` is built or deployed.

## Release/install topology

The production model is:

```text
one repository
one Git update
connector-specific front-end installers
one shared combined-DLL build/runtime-safety engine
```

The operator selects the connector front end required on a host, for example:

```bash
git pull --ff-only
sudo ./tools/brimstone-s4-install.sh install
```

MEGA Cloud uses its own front-end installer when promoted to canonical production status.

Both front ends must consume the same shared builder/runtime safety layer. Neither is allowed to compile or deploy an `ASC.Files.Thirdparty.dll` that removes the other provider.

Shared responsibilities include:

- exact platform/image preflight;
- pinned CommunityServer source baseline;
- combined DLL construction;
- provider-contract validation;
- runtime backup;
- external-MySQL protection;
- minimum-scope CommunityServer restart;
- post-restart health checks;
- rollback state.

Connector front ends may additionally own their provider-specific UI, handler, native/runtime dependencies and acceptance probes.

The detailed production contract is recorded in `docs/BRIMSTONE-COMBINED-INSTALL.md`.

## Shared provider assembly

The custom `ASC.Files.Thirdparty.dll` contains both:

- `ASC.Files.Thirdparty.MegaS4`
- `ASC.Files.Thirdparty.BrimstoneMegaCloud`

The shared assembly is therefore an atomic provider unit even though the operator-facing installers are connector-specific.

## MEGA S4 path

MEGA S4 uses S3-compatible semantics while presenting buckets/prefixes/objects through ONLYOFFICE's connected-storage model.

Current accepted responsibilities include:

- endpoint and signing-region configuration;
- path-style addressing;
- saved access/secret credentials;
- bucket discovery and selection;
- prefix-as-folder mapping;
- object listing;
- file/folder creation;
- upload/download;
- rename/move/copy/delete;
- provider/account persistence through ONLYOFFICE's third-party account path.

The browser-accepted external ID contract is:

```text
sboxmega-<providerId>
sboxmega-<providerId>-<base64url-key>
```

The historical/intermediate `sbox-megas4-` namespace is forbidden.

The accepted S4 browser layer is a cumulative v1/v2/v3/v4.1 overlay with the legacy v3 `MutationObserver` disabled and the guarded v4.1 observer active.

### Accepted Safari limitations

A saved MEGA S4 connection is treated as immutable for endpoint, credentials and bucket selection. Change those values by deleting/recreating the account.

Safari may retain a stale Connected Clouds JavaScript session where an existing saved account/settings view works but `Connect cloud -> MEGA S4` does not respond. A Safari Private Window is the proven clean-session workaround for creating/recreating the connection.

## MEGA Cloud path

The normal MEGA Cloud provider is compiled into the shared assembly and has its own development milestones for browse, create/edit and full-write behaviour.

Its production front end must ultimately own any native MEGA runtime dependency from this same repository, with pinned versions and no second operator-managed checkout or manual library-copy process.

When promoted, the Cloud installer must use the same shared combined-DLL builder/runtime-safety layer used by S4.

## Compatibility baseline

Current accepted target:

```text
ONLYOFFICE CommunityServer image: onlyoffice/communityserver:12.8.0.1971
CommunityServer source commit: fe1fa7babd093969e939ba6ff45a9fee1299dc93
```

Unsupported builds must fail closed rather than receive speculative runtime patches.

## Repository boundaries

`ONLYOFFICE-Community-Storage-Profiles` remains responsible for backend/static object storage, backup and restore.

This repository owns user-facing connected-cloud-storage integrations exposed through the ONLYOFFICE Files product.

Historical versioned documents remain development evidence and should not override the current accepted release documents:

- `STATUS.md`
- `docs/INSTALL-S4.md`
- `docs/MEGA-S4-ACCEPTED-2026-08-20.md`
- `docs/BRIMSTONE-COMBINED-INSTALL.md`
