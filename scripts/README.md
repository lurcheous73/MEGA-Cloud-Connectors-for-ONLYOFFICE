# Installer tooling

This directory contains deterministic build/verification tooling and will contain the reversible live installer/status/rollback tooling for the ONLYOFFICE MEGA connectors.

Current MEGA S4 tooling:

- `patch-communityserver-12.8-mega-s4.py` — fail-closed source integration patch for exact CommunityServer 12.8 baseline.
- `build-communityserver-12.8-mega-s4-linux.sh` — Linux/Mono build against the exact live CommunityServer 12.8 binaries using the Microsoft net48 reference pack as build-only scaffolding.
- `verify-mega-s4-dll.sh` — CLR metadata and AWS assembly-reference validation; does not rely on GNU `strings`.

Rules:

- exact build/image preflight
- backup every modified live file before installation
- preserve ownership and mode
- no credentials in arguments, output or Git
- no automatic provider activation during installation
- explicit status and rollback paths
- fail closed on unknown hashes/layouts
- validate CLR types and runtime dependencies before deployment
- automatically restore originals if a post-install health check fails
