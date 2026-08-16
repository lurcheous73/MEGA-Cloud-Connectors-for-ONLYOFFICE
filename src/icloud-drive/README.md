# iCloud Drive provider

Live connected-storage provider for ONLYOFFICE Files.

Planned provider surface:

- authenticate / 2FA / trusted session
- list root and folders
- file metadata
- stream download
- upload / replace
- create folder
- rename / move
- delete
- conflict/error mapping into ONLYOFFICE semantics
- disconnect and local session cleanup

Implementation must remain a direct provider integration. No rclone, FUSE, WebDAV bridge or local mirror is part of the design.
