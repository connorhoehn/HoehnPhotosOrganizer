# Agent Onboarding Audit — HoehnPhotosOrganizer

**Date:** 2026-05-05  
**Agent:** HoehnPhotosOrganizer  
**Purpose:** Establish Current Phase, Phase north-star, and self-driven backlog for constitution refresh.

---

## 1. Project Summary

**HoehnPhotosOrganizer** is a personal photo management and creative studio application targeting macOS (primary) and iOS (companion). Built with SwiftUI, GRDB (SQLite), CoreML, and OpenCV.

| Target | Role |
|--------|------|
| `HoehnPhotosOrganizer` | macOS app — full feature set, primary engine |
| `HoehnPhotosMobile` | iOS companion — browse, curate, monitor |
| `HoehnPhotosCore` | Shared framework — models, database, auth, sync |
| `infra/` | AWS CDK backend — Cognito + S3 + DynamoDB + API Gateway |

---

## 2. Planning Docs Found

No `.planning/` directory exists. Planning state was reconstructed from:
- `iOS-HANDOFF.md` — 15-session iOS build plan
- `ios-handoffs/` — 15 per-session detailed plans (sessions 1–15)
- `ios-handoffs/cloudkit-sync-plan.md` — CloudKit → AWS sync evolution
- `infra/README.md` — AWS CDK 4-wave implementation plan
- `README.md` — feature list and project structure
- Git log (10 commits)

---

## 3. Git History Analysis

```
5e719e1 chore: add Claude Code settings with agent-hub MCP permissions
e07d696 agent: add CONSTITUTION.md (north star for self-driven work)
1c6e498 a11y: add selection traits + value to photo-detail curation buttons
0f7dc5e iOS UX polish: real face-chip actions, sign-out, haptics + a11y
dcbbab1 fix: unblock Mac-app compile with type-inference and ForEach fixes
62a399f AWS sync stack + Cognito PKCE auth, CloudKit made opt-in
0f062db iOS design system + Library/Search/People/Detail polish
0fce7c4 docs: add screenshots to README
66a36e1 docs: add README
6215e2e Initial commit — HoehnPhotosOrganizer
```

**Trajectory:** Initial bootstrap → docs → AWS sync + Cognito → iOS design system polish → Mac compile fixes → iOS UX polish + a11y → agent bootstrap.

---

## 4. iOS Session Progress (from ios-handoffs + file existence check)

| Session | Topic | Files Present | Status |
|---------|-------|--------------|--------|
| 1 | Library cleanup + metadata sheet | `MobilePhotoDetailView.swift` | ✅ Done |
| 2 | Library curation UX | `BentoSectionView.swift`, `CurationActionBar.swift` | ✅ Done |
| 3 | People redesign | `MobilePeopleView.swift`, `FaceCropCache.swift`, `PeopleReviewView.swift` | ✅ Done |
| 4 | Jobs task cards | `MobileJobsView.swift` | ✅ Done |
| 5 | Jobs filmstrip + actions | (same file) | ✅ Done |
| 6 | Activity filters + detail | `MobileActivityView.swift`, `MobileEventDetailView.swift` | ✅ Done |
| 7 | Search filters | `MobileSearchView.swift`, `MapResultsView.swift` | ✅ Done |
| 8 | Creative tab + repos | `MobileCreativeView.swift` | ✅ Done |
| 9 | Studio gallery + detail | `MobileStudioGalleryView.swift`, `MobileStudioDetailView.swift`, `MobileStudioHistoryView.swift` | ✅ Done |
| 10 | PrintLab history + detail | `MobilePrintLabView.swift`, `MobilePrintDetailView.swift` | ✅ Done |
| 11 | Skeleton loaders | `BentoSkeletonSection.swift` (Library only) | ⚠️ Partial |
| 12 | Context menus + swipe | Recent commit: "real face-chip actions" | ⚠️ Partial |
| 13 | Dark mode audit | No evidence of systematic pass | ❌ Not started |
| 14 | Animations | No evidence of systematic pass | ❌ Not started |
| 15 | Accessibility + final polish | Recent commits; session doc has unchecked items | ⚠️ In progress |

**~10–11 of 15 sessions complete.** Sessions 11-15 (polish) are partially or not done.

---

## 5. macOS App Status

Very feature-rich. 23 feature directories + full AI pipeline system:

**Features:** ActivityFeed, Auth, Collections, Curation, Debug, DetailPanel, Develop, Discovery, Drives, Duplicates, Enrichment, Import, Inspector, Jobs, Navigation, People, Pipelines, PrintLab, Search, Settings, Storage, Studio, Workflows, Workspace

**AI modules:** DustRemoval, EditorialCritique, Embeddings, FaceRecognition, JobBucketing, Rendering, SceneDetection, Segmentation, Vision

**Active work area** (from git diff — modified files, unstaged):
- `HoehnPhotosCore/Auth/*` — Cognito PKCE auth refinements
- `HoehnPhotosCore/Sync/*` — CloudSyncEngine/Pull/Push modifications
- `HoehnPhotosMobile/*` — iOS UX and auth changes
- `HoehnPhotosOrganizer/AI/DustRemoval/*` — batch pipeline work
- `HoehnPhotosOrganizer/Features/Navigation/SidebarRail.swift`
- `HoehnPhotosOrganizer/Features/People/FaceGalleryView.swift`
- `infra/cdk.out/*` — CDK synth output present (not deployed from agent)

---

## 6. Sync Architecture

The project has evolved from Multipeer Connectivity → AWS cloud sync:

- `CloudSyncEngine` + `CloudSyncPull` + `CloudSyncPush` — AWS-backed sync
- `AWSPhotoSyncClient` — presigned URL client against API Gateway
- `CognitoAuthClient` — PKCE OAuth2 auth with Cognito
- CloudKit is now opt-in (per commit `62a399f`)
- Infra: 4-wave CDK plan — Wave 1 (S3/DynamoDB), Wave 2 (Lambda/presigned URLs/Cognito), Waves 3–4 (Swift client, restore flow) — likely Wave 2 shipped based on git history

---

## 7. Test Suite Baseline

**Command attempted:** `xcodebuild test -scheme HoehnPhotosOrganizer -destination 'platform=macOS'`

**Result: FAILED (pre-existing)**

```
HoehnPhotosCoreTests linker error:
  Undefined symbol: GRDB.DatabaseWriter.write<A>(...) ...
  [17 undefined GRDB symbols total]
  Linker command failed with exit code 1
```

- **HoehnPhotosOrganizerTests**: 94 test files — could not run (build aborted due to above)
- **HoehnPhotosCoreTests**: 4 test files — link error (GRDB symbols undefined)
- **Root cause**: `HoehnPhotosCoreTests` target is not correctly linking the GRDB SPM package

**Follow-up tasks filed separately** (see Section 9).

---

## 8. Current Phase (Proposed)

### Phase: iOS Polish Completion + AWS Sync Hardening

**North-star:** Ship the iOS companion app to a "demo-ready" quality bar — all 15 sessions complete, dark mode working, animations polished, accessibility full-pass done. In parallel, harden the AWS cloud sync layer so it's robust enough for day-to-day use.

**Why this now:** Sessions 1–10 are done; the iOS app is functional but unpolished. Sessions 11–15 are the last mile. Meanwhile the AWS sync is the most critical infrastructure piece — it's partially done but untested. Fixing the test suite (GRDB linker error) is a blocker for all test coverage work.

---

## 9. Self-Driven Backlog (Proposed — Ranked)

| Rank | Item | Criterion met | Est. LOC | Pick-this-if |
|------|------|--------------|----------|-------------|
| 1 | Fix HoehnPhotosCoreTests GRDB linker error | Removes test blocker | ~20–50 | Tests can't run at all — highest leverage |
| 2 | iOS Session 15: complete remaining a11y items | Closes documented checklist | ~80–120 | session-15 has unchecked items |
| 3 | iOS Session 13: dark mode color audit | Closes documented session | ~100–150 | App ships with dark mode looking broken |
| 4 | iOS Session 14: spring animations pass | Closes documented session | ~80–100 | Quick win; listed pass is well-defined |
| 5 | iOS Session 11: skeleton loaders for non-Library tabs | Closes documented session | ~80–120 | Spinner UX is rough in Jobs/People/Activity |
| 6 | AWS sync error UX: LoginView graceful Cognito error states | Hardens recently-shipped auth | ~60–100 | Auth failures show nothing to user |
| 7 | FaceGalleryView a11y + empty state (Mac) | Hardens recently-modified file | ~40–80 | File in diff; surface area is small |
| 8 | SidebarRail keyboard navigation (Mac) | Improves operator ergonomics | ~60–100 | File in diff; keyboard nav gaps common |
| 9 | BatchDustRemoval progress reporting | Improves operator visibility | ~60–100 | Pipeline is in diff; long-running ops need feedback |
| 10 | AWS sync integration test: pull conflict resolution | Adds test coverage for critical path | ~100–150 | AWS sync is untested; conflict resolution is risky |

---

## 10. Constitution Refresh Recommendations

1. **Current phase** → "iOS Polish Completion + AWS Sync Hardening" (as above)
2. **Phase north-star** → Demo-ready iOS companion, passing test suite, robust AWS sync
3. **Self-driven backlog** → Items 1–10 from Section 9
4. **User-facing framing personas** → End-user: photographer using iOS app; Operator: developer/owner debugging sync or running the Mac app
5. **LOC cap** → Keep at 150–200 LOC per task; the work items above all fit
6. **Cross-repo contracts** → None; this is a leaf application (no consumers)

---

## 11. Files Reviewed

- `README.md`
- `iOS-HANDOFF.md`
- `ios-handoffs/session-01-library-cleanup.md` through `session-15-accessibility.md`
- `ios-handoffs/cloudkit-sync-plan.md`
- `infra/README.md`
- `.agent/CONSTITUTION.md`
- Directory listings for all feature targets
- Git log (all 10 commits)
- xcodebuild test output
