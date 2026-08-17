# BRIMSTONE combined connector install contract

## Final operator experience

The production release of this repository MUST install and update both user-facing connectors from one checked-out repository state:

- Brimstone MEGA S4
- Brimstone MEGA Cloud

The intended final operator flow is deliberately one pull and one installer entry point, for example:

```bash
git pull
sudo ./tools/brimstone-install.sh install
```

The exact final command name may change before release, but the one-repository / one-installer contract does not.

## Atomicity and safety

The combined installer must treat the two connectors as one release unit while validating each connector independently.

Required behaviour:

1. Fail closed on unsupported ONLYOFFICE image/build/hash combinations.
2. Refuse a dirty or unexpected repository state when exact release validation is required.
3. Back up every runtime file that will be replaced before changing anything.
4. Protect the external `onlyoffice-mysql-server`; CommunityServer restart logic must never issue a client shutdown against the external MySQL container.
5. Install shared dependencies once, then install Brimstone MEGA S4 and Brimstone MEGA Cloud payloads.
6. Preserve existing ONLYOFFICE providers and existing connected accounts.
7. Restart only the minimum required component, normally CommunityServer, never the whole stack as a convenience shortcut.
8. Run a common platform health check plus separate S4 and Cloud connector health checks.
9. If either connector fails install-time acceptance, roll the whole release back to the pre-install snapshot unless the operator explicitly selected a connector-specific development mode.
10. Verify protected invariants after restart, including MySQL `RestartCount`/`StartedAt` and locked runtime hashes where applicable.

## Release layout

Development may remain split into connector-specific source trees and test tools, but the release tree must converge on a shared layout similar to:

```text
src/
  mega-s4/
  mega-cloud/
tools/
  brimstone-install.sh        # production entry point for BOTH
  brimstone-status.sh         # reports BOTH
  brimstone-rollback.sh       # release rollback for BOTH
  dev/                        # connector-specific development helpers
```

All custom code, generated metadata, runtime markers, backups and log prefixes created by this project must retain an obvious `BRIMSTONE` / `Brimstone` identity.

## Dependency ownership

Any native MEGA SDK component required by Brimstone MEGA Cloud must be installed by the same production installer and version-pinned by the repository. The operator must not need to clone a second repository, run an unrelated SDK installer, manually copy libraries, or maintain a separate checkout.

Third-party source can be built or packaged during the release engineering process, but the deployed release must remain reproducible from this repository's pinned manifest/build instructions.

## Upgrade rule

A future `git pull` followed by the production installer must be able to detect the currently installed Brimstone release and safely upgrade both connectors together. Re-running the same release must be idempotent or explicitly report that no change is required.

## Development exception

During development, S4 and Cloud may be installed/tested independently to reduce blast radius. That is a development convenience only and must not become the final operator workflow.
