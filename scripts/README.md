# Installer tooling

This directory will contain reversible install/status/rollback tooling once the ONLYOFFICE provider integration points are confirmed.

Rules:

- exact build/image preflight
- backup every modified file
- preserve ownership and mode
- no credentials in arguments, output or Git
- no automatic provider activation during installation
- explicit rollback path
