# HoehnPhotosOrganizerTests — XCTest Scaffolding

This directory contains the test sources. Four new XCTest files were added to verify
recently-changed behavior:

| File                                       | What it pins                                                    |
| ------------------------------------------ | --------------------------------------------------------------- |
| `PhotoRepositoryGateTests.swift`           | `import_status = 'library'` gate on `fetchAll` / `fetchByIds`.  |
| `FaceEmbeddingRepositoryGateTests.swift`   | People-gallery gating + ungated job-scoped path.                |
| `ImageAdjustmentServiceResultTests.swift`  | `ApplyResult` surfaces per-photo failures (not just successes). |
| `TriageJobCompletenessTests.swift`         | Consolidated `computeAndUpdateCompleteness` returns the same    |
|                                            | 4-dimension average as the pre-consolidation implementation.    |

## Wiring into an Xcode test target

The four new `.swift` files are **not yet attached to a target**. They use
`@testable import HoehnPhotosOrganizer` so they need to live in a target that:

1. Is configured as a Unit Testing Bundle.
2. Has `HoehnPhotosOrganizer` listed under **Target Dependencies**.
3. Has `Enable Testability = YES` on the `HoehnPhotosOrganizer` target (Debug config).

### Steps in Xcode

1. Open `HoehnPhotosOrganizer.xcodeproj`.
2. Project navigator → select the **HoehnPhotosOrganizerTests** target. (If it does
   not exist, add one via *File → New → Target… → macOS → Unit Testing Bundle*; set
   the "Target to be Tested" to `HoehnPhotosOrganizer`.)
3. Build Phases → **Compile Sources** → click `+` and add the four new files:
   - `PhotoRepositoryGateTests.swift`
   - `FaceEmbeddingRepositoryGateTests.swift`
   - `ImageAdjustmentServiceResultTests.swift`
   - `TriageJobCompletenessTests.swift`
4. Verify the test target's **General → Frameworks and Libraries** lists `GRDB`
   (transitively pulled via `HoehnPhotosOrganizer`, but explicit linkage helps for
   tests that import `GRDB` directly).
5. Cmd-U to run the suite, or `xcodebuild test -scheme HoehnPhotosOrganizer
   -destination 'platform=macOS'` from the command line.

## Notes & known limitations

### `FaceEmbeddingRepositoryGateTests.testFindSimilarPhotoIdsExcludesStaged`

`FaceEmbeddingService.distance` deserializes `VNFeaturePrintObservation` from the
stored `feature_data` blob. The unit tests do not run Vision against real images,
so the opaque bytes used for `featureData` cannot be deserialized and `distance`
returns nil for every candidate. The assertion this test makes is the strongest
one possible without a real face image:

> The staged photo's ID must **never** appear in the result set of
> `findSimilarPhotoIds(to:)`.

The library-only filter is applied **before** the distance computation in the
implementation, so even when distance is non-nil this gate still holds. If you want
a stronger end-to-end test, add a fixture image and run
`FaceEmbeddingService.generateFeaturePrint(for:)` in the setup phase.

### `TriageJobCompletenessTests` — `development_versions` table

`computeAndUpdateCompleteness` references the `development_versions` table, which
is created by the **HoehnPhotosCore** schema but not by `HoehnPhotosOrganizer`'s
own `AppDatabase` migrations. The test creates the table manually in `setUp` so the
nested `SELECT … FROM development_versions` does not error. If the macOS app starts
running its own development versions migration, this manual `CREATE TABLE` can be
removed.

### In-memory database

All four suites use `AppDatabase.makeInMemory()` which builds a fresh
`DatabaseQueue(":memory:")` and runs every migration. No file cleanup is needed for
the DB itself; the `setUp`/`tearDown` pattern just nils the references.
`ImageAdjustmentServiceResultTests` additionally creates a UUID-named temp
directory under `FileManager.default.temporaryDirectory` for the successful sidecar
writes, and removes it in `tearDown`.

## If a test fails to compile

The most likely cause is `@testable import HoehnPhotosOrganizer` not resolving:

- Verify `HoehnPhotosOrganizer` builds for testing (Debug config, `ENABLE_TESTABILITY=YES`).
- Confirm the test target's **Host Application** is `HoehnPhotosOrganizer` (Build
  Settings → `TEST_HOST`).
- Some accessed types are internal (`PhotoRepository`, `FaceEmbeddingRepository`,
  `TriageJobRepository`, `ImageAdjustmentService`, `ApplyResult`). `@testable`
  exposes them; without it you will see "cannot find type ..." errors.
