# Contributor workflow

- Read `README.md` for setup, features, data handling, and build/test commands.
- Keep device signing and CloudKit identifiers in the ignored `Config/Local.xcconfig`. Do not commit certificates, profiles, personal notes, exported archives, or credentials.
- Preserve local data compatibility and existing note/reminder links. Cover persistence, recognition, and synchronization changes with focused regression tests.
- Run the relevant simulator tests and a simulator build after app changes. Report skipped integration tests and any limitations of the verification. Device installation is optional and requires an available, configured device.
- Keep this public variant free of the experimental chat implementation. Do not import private development history or local service tooling.
- Before publication, verify the chosen license and the provenance of bundled graphics and handwriting fixtures.
- Do not change graphics, design, or app behavior because of rights or licensing concerns without the user’s prior explicit decision. Raise such concerns with the user before making changes.
