# BRIMSTONE MEGA Cloud v0.001cc

## Purpose

`v0.001cc-mega-cloud` is the first normal-MEGA development line. It proves the official MEGA client engine, normal account authentication, live Cloud Drive browsing and saved-session resume in isolation before any new code is deployed into ONLYOFFICE CommunityServer.

The existing MEGA S4 connector remains untouched. The final production release still follows `BRIMSTONE-COMBINED-INSTALL.md`: one repository pull and one production installer installs/updates both Brimstone MEGA S4 and Brimstone MEGA Cloud.

## Pinned upstream

Normal MEGA Cloud uses the unmodified official MEGAcmd client engine and its bundled MEGA SDK:

- MEGAcmd version: `2.5.2`
- MEGAcmd commit: `4b291975aafa7332ddfbf1a689455ebd972adff4`
- bundled MEGA SDK commit: `fae76a36d60484657fbdf442b7b917ccc4fbad77`
- vcpkg baseline: `ef7dbf94b9198bc58f45951adcf1f041fcbc5ea0`
- CMake: `3.30.5`

These values live in `src/mega-cloud/native/BRIMSTONE-MEGACMD-MANIFEST.env` and must not float silently.

The older raw-SDK probe remains useful development evidence, but it is not the accepted normal-MEGA authentication path because the Connected Cloud contract does not expose or request a user-supplied MEGA application key.

## Authentication/session design

The user-facing contract is deliberately normal MEGA authentication:

1. Initial connection uses MEGA email/username + password.
2. MFA is supplied only when MEGA challenges an account that requires it.
3. The password is bootstrap material only and must not be retained by the Brimstone provider.
4. Each provider slot receives an isolated `HOME` and `MEGACMD_SOCKET_NAME`, separating MEGAcmd session/cache/socket state between connected accounts.
5. Subsequent access resumes from the official MEGAcmd saved session without supplying the password again.
6. If MEGA rejects/revokes the saved session, the provider will enter a re-authentication state rather than silently retaining or replaying the password.

The exact production mapping between isolated MEGAcmd session state and ONLYOFFICE third-party-account storage is a v0.002cc integration task and is not claimed as complete in v0.001cc.

## Build/runtime isolation

The development harness is `tools/BRIMSTONE-v0.001cc-megacmd-engine.sh`.

It builds the pinned, unmodified official MEGAcmd source in a disposable container created from the exact target image `onlyoffice/communityserver:12.8.0.1971`. It does not install packages in the live CommunityServer container, modify the live ONLYOFFICE filesystem, or restart live services.

The build uses the SDK sync API because the pinned upstream MEGAcmd source itself compiles against sync-related SDK types and interfaces. Brimstone does not create, configure or invoke MEGA sync jobs. `WITH_FUSE=OFF`; Connected Cloud operations remain direct remote operations through the official MEGA engine.

## v0.001cc acceptance — PASS 17 August 2026

The following were demonstrated against a real normal MEGA account without recording account identifiers, filenames or credentials in this repository:

1. Official MEGAcmd `2.5.2` builds successfully against the exact CommunityServer runtime image.
2. Initial authentication succeeds with email/username + password and no user-supplied application key.
3. MEGAcmd completes its node fetch after authentication.
4. The real Cloud Drive root is listed successfully.
5. A nested Cloud Drive folder is entered and its children are listed successfully.
6. `whoami` confirms the authenticated account.
7. The interactive test is exited with `quit`, not `logout`, preserving the session.
8. A fresh process using the same isolated provider slot resumes the saved MEGAcmd session without supplying a password.
9. One-shot `whoami` and root-list operations succeed from the resumed session.
10. The resumed root matches the previously browsed live Cloud Drive.
11. No live ONLYOFFICE container is modified or restarted during acceptance.

MFA handling is provided by the official MEGAcmd authentication path, but the MFA branch is not recorded as runtime-proven by this acceptance because the test account did not require an MFA challenge.

## Frozen acceptance baseline

After this acceptance note is committed, the accepted commit is frozen on a dedicated baseline branch. That branch must not be moved or modified. Development continues from a new `v0.002cc-mega-cloud` branch created from the same accepted commit.

## Next milestone: v0.002cc

`v0.002cc` introduces the first ONLYOFFICE integration layer while preserving the accepted official MEGA engine underneath it.

Scope for v0.002cc:

- register a distinct Brimstone MEGA Cloud third-party provider in CommunityServer;
- map a provider account to isolated MEGAcmd session/socket state;
- use stable MEGA node identity rather than path as the canonical object identity;
- show the real normal-MEGA Cloud Drive root and folder browsing inside ONLYOFFICE Files;
- keep S4 provider behaviour untouched;
- no upload/download/editor-save implementation yet unless required by the minimum provider browse contract.

The provider namespace remains separate from S4 and all new custom code/classes/markers retain Brimstone identity.

No sync client, FUSE mount, rclone, WebDAV or cron layer is part of this design.
