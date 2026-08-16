# MEGA S4 first-pass implementation note

Branch: `feature/mega-s4`

The first native provider pass is now in source form. It maps the stock ONLYOFFICE `ASC.Files.Thirdparty` selector/DAO architecture directly to MEGA S4 through `AWSSDK.S3` 4.0.19.2.

Implemented source areas:

- provider/account settings and encrypted token payload;
- collision-safe provider IDs;
- provider info and selector;
- S3 storage/API client;
- file/folder DAO operations;
- chunked multipart upload;
- verified move/copy semantics;
- no-op third-party sharing/tag policy matching the existing connected-storage model;
- Community Server integration patch.

This pass has **not** yet been compiled against the exact Community Server 12.8 build and is deliberately not an installer/release. The next gate is the connection UI plus source compilation in a disposable/test build.
