# BRIMSTONE connector status — accepted 20 August 2026

Current release branch:

```text
release/working-connectors-20260820
```

Supported CommunityServer image:

```text
onlyoffice/communityserver:12.8.0.1971
```

Pinned CommunityServer source commit:

```text
fe1fa7babd093969e939ba6ff45a9fee1299dc93
```

## Shared provider assembly

`ASC.Files.Thirdparty.dll` contains both custom providers:

- `ASC.Files.Thirdparty.MegaS4`
- `ASC.Files.Thirdparty.BrimstoneMegaCloud`

Both connector front-ends must preserve this combined-provider contract.

The browser-accepted MEGA S4 DLL observed during acceptance had SHA-256:

```text
aa5ffeb00446c44eefaf48d91d045271cbf62405fb8753024a10bb7c8bf84226
```

Canonical rebuilds are validated by provider/runtime contracts rather than requiring byte-for-byte reproduction of that historical build hash.

## MEGA S4 transport and Files integration — PROVEN

MEGA S4 remains configured against:

```text
endpoint: https://s3.g.megas4.com
signing region: g
```

Direct SigV4 transport previously proved `ListBuckets` and `ListObjectsV2` with HTTP 200 responses.

Authenticated ONLYOFFICE Files acceptance now proves:

- saved MEGA S4 connection opens normally;
- bucket/prefix browsing works;
- folders can be created;
- files can be created/written;
- objects can be moved;
- objects can be copied;
- files/folders can be renamed;
- delete works;
- saved connection settings open;
- `Pull buckets` returns the live S4 bucket list;
- a new connection can be created from a clean Safari Private Window session.

## Accepted ID namespace

The browser-tested namespace is:

```text
sboxmega-<providerId>
sboxmega-<providerId>-<base64url-key>
```

The historical/intermediate namespace:

```text
sbox-megas4-
```

must not be compiled or deployed.

## Accepted S4 handler topology

The working runtime uses both:

```text
/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx
/var/www/onlyoffice/WebStudio/bin/brimstone-megas4.ashx.brimstone.compiled
```

The physical `.ashx` contains the Brimstone source handler directive and has accepted SHA-256:

```text
b965422c50d04294e8e1d446e397dfd6fa3477b531b0df0bd179d670d8861b44
```

Exactly one `.compiled` metadata file maps that route to:

```text
ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler
```

No temporary Brimstone `Web.config` handler mapping is required. An anonymous local route probe resolving as HTTP 401 proves the compiled handler path executes instead of falling into Mono's dynamic `.ashx` parser.

## Accepted Safari UI

The cumulative accepted UI overlay contains:

- v1
- v2
- v3 layout normaliser
- legacy v3 `MutationObserver` disabled
- guarded v4.1 observer

Accepted overlay SHA-256:

```text
ee90cfbd7e6ed94008e555e501bde917b39677c49da8a47924112c614888f967
```

The legacy v3 observer caused a Safari mutation feedback loop. The accepted build keeps the v3 layout logic but disables only that observer; v4.1 owns guarded observation/normalisation.

## Known accepted browser limitations

1. **Saved connection settings are effectively immutable.** Endpoint, access key, secret key and bucket selection are not supported as an in-place edit. Delete/recreate the connection when those values must change.
2. **Safari stale-session issue.** Safari can retain a Connected Clouds JavaScript session in which the existing MEGA S4 account/settings view opens but `Connect cloud -> MEGA S4` does not respond.
3. **Proven workaround.** Use a Safari Private Window for a clean session when creating/recreating a MEGA S4 connection. Emptying caches and reloading may also clear the stale condition.
4. The stale-session symptom is not by itself a provider/backend failure when the existing connection still opens.

These are documented accepted limitations, not blockers to the current working S4 connector.

## External MySQL protection

On the accepted 20 August 2026 production container, `/app/run-community-server.sh` contained one exact bare:

```text
mysqladmin shutdown
```

while `root.cnf` targeted `onlyoffice-mysql-server`.

The canonical installer counts exact vulnerable shutdown lines rather than assuming a hard-coded number and replaces each with the local-socket-only guarded form:

```text
mysqladmin --no-defaults --protocol=socket --socket=/var/run/mysqld/mysqld.sock shutdown || true
```

Verification requires an unmixed safe state and checks that external MySQL `RestartCount` and `StartedAt` remain unchanged across a CommunityServer restart.

## Canonical release tooling

Production S4 tooling on this branch:

```text
tools/lib/brimstone-connectors-common.sh
tools/brimstone-build-combined.sh
tools/brimstone-s4-install.sh
```

Operator commands:

```bash
./tools/brimstone-s4-install.sh status
./tools/brimstone-s4-install.sh verify
./tools/brimstone-s4-install.sh install
./tools/brimstone-s4-install.sh rollback
```

The release architecture is one repository and one Git update with two connector-specific front-ends sharing the same combined-DLL build/runtime safety engine.

## MEGA Cloud

The normal MEGA Cloud provider remains compiled into the shared DLL. Its earlier read/write/full-write milestones and versioned development documentation remain historical evidence. A separate canonical MEGA Cloud production front-end is still to be promoted onto the shared release engine once its runtime dependencies are packaged cleanly.

## Current position

MEGA S4 is browser-accepted and operational with the documented Safari limitations above. Do not revive old v0.001/v0.005 assumptions or historical `sbox-megas4-` IDs when working from this release branch.
