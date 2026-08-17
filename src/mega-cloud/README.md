# BRIMSTONE MEGA Cloud connector

Implementation area for the normal `mega.nz` connected-storage provider.

## v0.001cc authentication contract

The ONLYOFFICE Connected Cloud form must request only:

- folder title
- MEGA email/username
- MEGA password

If MEGA requires MFA, the one-time authentication code is requested only as part of that challenge. There is no application-key field in the user interface.

After the first successful login, normal reconnects must use the MEGA session so the account password does not need to remain the day-to-day transport credential.

## Native engine decision

The direct official MEGA SDK probe successfully built and proved that the SDK can be packaged against the ONLYOFFICE CommunityServer 12.8 runtime. However, the raw SDK still expects an application identifier while MEGA no longer exposes an application-key registration workflow to the user.

For the production connector, v0.001cc therefore tests **unmodified official MEGAcmd** as the native MEGA engine. MEGAcmd presents the required email/password/MFA/session login contract and owns its own MEGA client identity.

BRIMSTONE does not copy, expose or impersonate MEGAcmd's internal application identifier.

## Per-provider isolation

MEGAcmd supports an isolated configuration/session directory via `HOME` and an independently named Unix socket via `MEGACMD_SOCKET_NAME`.

Each future ONLYOFFICE provider account can therefore use its own state and socket, for example:

```text
HOME=/var/lib/brimstone-mega/<provider-id>
MEGACMD_SOCKET_NAME=brimstone-mega-<provider-id>.socket
```

This keeps multiple MEGA accounts independent while using the same official MEGA engine.

The v0.001cc development probe runs this engine in disposable containers only and does not modify or restart the live ONLYOFFICE stack.
