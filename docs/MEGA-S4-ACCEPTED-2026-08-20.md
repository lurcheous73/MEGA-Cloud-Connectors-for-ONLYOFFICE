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
