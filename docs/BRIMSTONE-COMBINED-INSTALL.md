# BRIMSTONE combined connector install contract

## Final operator experience

The production release keeps both user-facing connectors in one repository and one checked-out release state:

- Brimstone MEGA S4
- Brimstone MEGA Cloud

The operator performs one Git update and then chooses the connector entry point required on that host:

```bash
git pull --ff-only
sudo ./tools/brimstone-s4-install.sh install
```

MEGA Cloud uses its own front-end installer when required:

```bash
sudo ./tools/brimstone-cloud-install.sh install
```

The two front ends MUST share the same combined `ASC.Files.Thirdparty.dll` builder and common runtime safety library. Neither installer is permitted to compile or deploy a connector-specific DLL that removes the other provider.

MEGA S4 is the first canonical production front end. The MEGA Cloud front end will be promoted onto the same shared engine after its separate runtime dependencies are packaged.

## Shared-DLL atomicity and safety

The repository treats the shared ONLYOFFICE provider assembly as one release unit while validating each provider independently.

Required behaviour:

1. Fail closed on unsupported ONLYOFFICE image/build combinations.
2. Refuse a dirty repository when exact release validation is required.
3. Build the shared assembly from one pinned CommunityServer source tree containing both Brimstone providers.
4. Reject the historical MEGA S4 `sbox-megas4-` namespace and require the browser-accepted `sboxmega-` namespace.
5. Back up every runtime file that will be replaced before changing anything.
6. Protect the external `onlyoffice-mysql-server`; CommunityServer restart logic must never issue a client shutdown against the external MySQL container.
7. Preserve stock ONLYOFFICE providers and existing connected-account rows.
8. Restart only the minimum required component, normally CommunityServer, never the whole stack as a convenience shortcut.
9. Run common platform health checks plus connector-specific runtime checks.
10. If a connector install fails after runtime mutation starts, restore the pre-install connector runtime automatically.
11. Verify protected invariants after restart, including MySQL `RestartCount` and `StartedAt`.
12. Re-running the same release must be idempotent or explicitly report that no change is required.

## Release layout

```text
src/
  mega-s4/
  mega-cloud/
tools/
  lib/
    brimstone-connectors-common.sh
  brimstone-build-combined.sh
  brimstone-s4-install.sh
  brimstone-cloud-install.sh       # promoted when Cloud packaging is complete
```

All custom code, generated metadata, runtime markers, backups and log prefixes created by this project retain an obvious `BRIMSTONE` / `Brimstone` identity.

## Shared builder ownership

`tools/brimstone-build-combined.sh` is the only production path that builds the custom `ASC.Files.Thirdparty.dll`.

It must always compile and validate both:

- `ASC.Files.Thirdparty.MegaS4`
- `ASC.Files.Thirdparty.BrimstoneMegaCloud`

A connector-specific installer may install additional UI, handlers or native/runtime dependencies, but it must consume the shared candidate produced by that builder.

## Dependency ownership

Any native MEGA SDK component required by Brimstone MEGA Cloud must be installed by the MEGA Cloud front end from a version-pinned repository manifest. The operator must not need an unrelated checkout or a manual library-copy procedure.

CommunityServer source used for the shared assembly is pinned by commit. The shared builder may bootstrap that source repository if the local build cache is absent.

## Upgrade rule

A future `git pull --ff-only` followed by either canonical connector installer must detect the current runtime, preserve the other provider in the shared assembly, back up the files it changes, and safely upgrade the selected connector.

The S4 canonical installer and its browser-accepted baseline are documented in `docs/INSTALL-S4.md`.
