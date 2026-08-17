# Test plan

Each connector will need a repeatable acceptance matrix before promotion to `main`.

Minimum coverage:

- authenticate / reconnect / disconnect
- list root and nested folders/prefixes
- upload small and large files
- download and verify SHA-256
- create folder/prefix
- rename and move
- delete
- restart persistence
- expiry / invalid-credential handling
- filename and Unicode edge cases
- large directory pagination
- no secret leakage in logs or browser persistence

MEGA Cloud and MEGA S4 are tested independently.
