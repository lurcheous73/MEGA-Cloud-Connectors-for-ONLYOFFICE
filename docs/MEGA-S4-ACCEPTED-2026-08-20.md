# Brimstone MEGA S4 — accepted working baseline

Accepted: 20 August 2026

Target:

- ONLYOFFICE CommunityServer 12.8.0.1971
- Brimstone MEGA S4
- Combined MEGA S4 + normal MEGA Cloud ASC.Files.Thirdparty.dll

## Browser acceptance

The following operations were successfully tested through ONLYOFFICE Files:

- open saved MEGA S4 connection
- browse bucket and folders
- create folder
- create/write file
- move
- copy
- rename
- delete
- open the saved connection settings and pull the live S4 bucket list
- create a new MEGA S4 connection from a clean Safari Private Window session

## Known accepted browser limitations

- A saved MEGA S4 connection is treated as immutable. Credentials, endpoint and bucket selection are not supported as an in-place edit; delete/recreate the connection to change them.
- Safari can retain a stale Connected Clouds JavaScript session in which the existing MEGA S4 account/settings view still opens but `Connect cloud -> MEGA S4` does not respond.
- A Safari **Private Window** is the proven workaround for creating/recreating a MEGA S4 connection when that stale-session condition occurs. Emptying Safari caches and reloading may also clear it.
- The stale-session symptom is not, by itself, evidence that the provider/backend is broken when the existing MEGA S4 connection continues to open.

These are accepted limitations of the 20 August 2026 working baseline and must be preserved in operator documentation until the UI is deliberately changed and browser-tested again.

## MEGA S4 ID contract

Accepted external ID namespace:

    sboxmega-<providerId>
    sboxmega-<providerId>-<base64url-key>

The obsolete namespace:

    sbox-megas4-

must never be compiled or deployed.

## Safari UI regression

The cumulative accepted UI consists of:

- v1
- v2
- v3 layout normaliser
- legacy v3 MutationObserver DISABLED
- v4.1 guarded MutationObserver

The old v3 observer caused a mutation feedback loop because the v3
normaliser re-appended credential rows while observing child-list
mutations.

The accepted UI keeps the v3 layout logic but disables only its
MutationObserver. v4.1 owns guarded observation and normalisation.

## Accepted combined DLL

SHA-256:

    aa5ffeb00446c44eefaf48d91d045271cbf62405fb8753024a10bb7c8bf84226

The DLL contains both:

- ASC.Files.Thirdparty.MegaS4
- ASC.Files.Thirdparty.BrimstoneMegaCloud

This combined-provider contract must be preserved by both installers.
