# App extension build trait

This branch adds the opt-in `AppExtensionSafe` Swift package trait to the
SQLiteData source at `e72164ceb92a10b62407624c98e5bc2c47d8c0e1`.

Enable the trait on the SQLiteData package dependency used by an app extension:

```swift
.package(
  url: "https://github.com/lake-of-fire/sqlite-data",
  revision: "<qualified revision>",
  traits: ["AppExtensionSafe"]
)
```

The trait defines `SQLITE_DATA_APP_EXTENSION` only for the `SQLiteData` target.
It excludes SyncEngine's iOS notification observer that uses
`UIApplication.shared` to obtain a containing-app background task. Builds that
do not enable the trait retain that observer and their existing behavior.
Database APIs and the default trait set are unchanged. The trait does not
enable CloudKit or create a SyncEngine, and it does not disable app-extension
API availability checking.

An extension still needs its own private writable store and an explicit
lifecycle. This source change does not make another process's synchronized
database an extension storage surface or grant App Group access.

## Portable verification

Run with Swift 6.4 or later:

```sh
python3 scripts/check-app-extension-trait.py --swift /path/to/swift
```

The check evaluates the real package manifest through SwiftPM, requires the
define to be conditional on this trait and scoped to the library target, and
checks that both existing app-singleton calls remain inside the extension
exclusion. It also verifies that the ordinary app's background-task calls and
notification are still present. It does not typecheck against an Apple SDK or
build an extension binary. Those checks remain necessary before device release.

The inherited CI workflow runs macOS jobs for pushes to `main` and for pull
requests. Publication of this dedicated dependency branch does not meet its
push trigger. No CI run, pull request or release is part of this qualification.
