# Next acceptance target

After v0.003, test in this order:

1. Download a file that was uploaded through ONLYOFFICE and verify its content.
2. Create or upload a DOCX into MEGA S4.
3. Open it in the ONLYOFFICE editor.
4. Make a unique edit and save.
5. Close and reopen the document from MEGA S4.
6. Verify the edited content persisted remotely.

Keep the following separate from the live-drive acceptance path:

- Pull Buckets helper runtime error.
- Existing-account editor UX.
- Shared S3-Compatible credential-import UX.
