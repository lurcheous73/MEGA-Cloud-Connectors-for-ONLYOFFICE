# Next work after 20 August 2026 acceptance

MEGA S4 core acceptance is complete on `release/working-connectors-20260820`.

Do **not** reopen the proven S4 transport/UI path casually. The accepted state and browser limitations are recorded in:

- `docs/MEGA-S4-ACCEPTED-2026-08-20.md`
- `docs/INSTALL-S4.md`
- `STATUS.md`

## Next priorities

1. Keep the accepted MEGA S4 runtime stable unless there is a deliberate browser-tested change.
2. Treat saved MEGA S4 endpoint/credential/bucket settings as immutable; delete/recreate when they must change.
3. Use a Safari Private Window when the normal Connected Clouds session leaves `Connect cloud -> MEGA S4` unresponsive.
4. Promote the separate MEGA Cloud production installer onto the same shared combined-DLL/runtime-safety engine.
5. Only after release testing, deliberately merge the working release branch to `main`.

Historical versioned acceptance documents remain evidence of the development path; they are not the current production status.
