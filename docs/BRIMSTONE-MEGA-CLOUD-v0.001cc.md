# BRIMSTONE MEGA Cloud v0.001cc

## Purpose

`v0.001cc-mega-cloud` is the first native-MEGA development line. It proves the official MEGA SDK lifecycle in isolation before any new code is deployed into ONLYOFFICE CommunityServer.

The existing MEGA S4 connector remains untouched. The final production release still follows `BRIMSTONE-COMBINED-INSTALL.md`: one repository pull and one production installer installs/updates both Brimstone MEGA S4 and Brimstone MEGA Cloud.

## Pinned upstream

- Official repository: `meganz/sdk`
- Tag: `v10.17.0`
- Commit: `51954a44aa3cfd8f0e2e5a82c23083d8cc250cc5`
- vcpkg baseline from that SDK release: `ef7dbf94b9198bc58f45951adcf1f041fcbc5ea0`

These values live in `src/mega-cloud/native/BRIMSTONE-SDK-MANIFEST.env` and must not float silently.

## Authentication/session design

The normal MEGA account password is bootstrap material only.

1. Initial connection uses email/password, or email/password/MFA when MEGA requires MFA.
2. After successful login and `fetchNodes`, Brimstone obtains the SDK session with `dumpSession()`.
3. Production ONLYOFFICE integration will persist the MEGA session through ONLYOFFICE's encrypted third-party-account storage, not retain the user's MEGA password.
4. Reconnection uses the saved session through `fastLogin(session)` followed by `fetchNodes()`.
5. If MEGA rejects/revokes the saved session, the connected drive enters a re-authentication state and requests fresh login/MFA rather than falling back to a stored password.

## v0.001cc native probe

Source:

- `src/mega-cloud/native/BrimstoneMegaCloudProbe.cpp`
- `src/mega-cloud/native/CMakeLists.txt`
- `tools/BRIMSTONE-v0.001cc-mega-cloud-probe.sh`

The tool builds in a disposable container created from the exact target image `onlyoffice/communityserver:12.8.0.1971`. It does not install packages in the live CommunityServer container, change the live filesystem, or restart any live service.

The first build automatically retrieves the two pinned development dependencies into the ignored local `build/mega-cloud-v0.001cc/` tree. This is development machinery only; the final production installer will own the packaged/pinned native dependency and will not require the operator to maintain a second repository checkout.

The probe accepts credentials only through process environment inherited by a disposable test container. Password and MFA values are never command-line arguments, never committed, and never included in successful JSON output. The resulting MEGA session is written only to the ignored disposable state directory with mode 0600.

## v0.001cc acceptance

The milestone is green only when all of the following are demonstrated against a normal MEGA account:

1. Official SDK builds against the exact CommunityServer runtime image.
2. Application-key authentication succeeds.
3. Email/password login succeeds.
4. MFA-required response is detected and the MFA login path succeeds when applicable.
5. `fetchNodes()` succeeds.
6. Cloud Drive root is returned.
7. Root child files/folders are enumerated with stable MEGA node handles.
8. A session is dumped without retaining the account password.
9. A second clean probe invocation resumes using the saved session and lists the same Cloud Drive root without the account password.
10. No live ONLYOFFICE container is modified or restarted during this acceptance.

## Next milestone after v0.001cc

`v0.002cc` will turn the proven native lifecycle into the local Brimstone MEGA Cloud bridge used by CommunityServer. The bridge will expose stable MEGA node handles and file operations to a new ONLYOFFICE third-party provider while keeping the native SDK out of Mono's process.

The intended provider namespace is separate from S4. A Cloud root/object ID grammar will use a dedicated `sboxmegacc-<providerId>` family so normal MEGA Cloud IDs cannot collide with the existing S4 `sboxmega-*` IDs.

No FUSE, sync client, rclone, WebDAV or cron layer is part of this design.
