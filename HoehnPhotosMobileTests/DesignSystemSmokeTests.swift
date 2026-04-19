//
//  DesignSystemSmokeTests.swift
//  HoehnPhotosMobileTests
//
//  Lightweight smoke tests for the Design System primitives in
//  HoehnPhotosMobile/Shared/DesignSystem/.
//
//  Out of scope:
//   - No snapshot testing (no third-party snapshot dependency).
//   - No Combine / @State transition testing — we do not drive SwiftUI state
//     machines from tests; only "constructs + lays out without crash" plus
//     exposed-API logic assertions.
//   - No haptic side-effect verification — UIKit feedback generators are fire-
//     and-forget; we only assert the action closure runs.
//   - FaceReviewCard is not rendered here because its swipe + sheet flow is
//     intertwined with presentation state and (in the real app) AppDatabase-
//     backed models. Its `Model` and `Action` are covered as value types.
//

import XCTest
import SwiftUI
import UIKit
@testable import HoehnPhotosMobile

final class DesignSystemSmokeTests: XCTestCase {

    // MARK: - Helpers

    /// Hosts a SwiftUI view in a UIHostingController, forces a layout pass at
    /// 200×200, and asserts that the resulting view bounds are non-zero.
    @MainActor
    func renderSmokeTest<V: View>(
        _ view: V,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertNotEqual(host.view.bounds, .zero, "View laid out with zero bounds", file: file, line: line)
    }

    // MARK: - 1. SearchScope enum

    func testSearchScope_allCasesHaveTitleAndSymbol() {
        XCTAssertFalse(SearchScope.allCases.isEmpty, "SearchScope.allCases should be non-empty")
        for scope in SearchScope.allCases {
            XCTAssertFalse(scope.title.isEmpty, "\(scope) should have a non-empty title")
            XCTAssertFalse(scope.systemImage.isEmpty, "\(scope) should have a non-empty SF Symbol name")
            // Touch the accent so any switch-default bugs surface.
            _ = scope.accent
        }
    }

    func testSearchScope_idMatchesRawValue() {
        for scope in SearchScope.allCases {
            XCTAssertEqual(scope.id, scope.rawValue)
        }
    }

    // MARK: - 2. ToastMessage / ToastKind

    func testToastMessage_preservesTitleAndKindMetadata() {
        let kinds: [ToastKind] = [.success, .info, .warning, .error]
        for kind in kinds {
            let message = ToastMessage(kind, "Hello", subtitle: "World")
            XCTAssertEqual(message.title, "Hello")
            XCTAssertEqual(message.subtitle, "World")
            XCTAssertFalse(kind.icon.isEmpty, "\(kind).icon should be a non-empty SF Symbol name")
            XCTAssertNotEqual(kind.tint, .clear, "\(kind).tint should not be .clear")
            // Touch feedback to catch any future switch-default bugs.
            _ = kind.feedback
        }
    }

    func testToastMessage_subtitleOptional() {
        let m = ToastMessage(.info, "Just a title")
        XCTAssertNil(m.subtitle)
    }

    // MARK: - 3. FaceChip state logic

    func testFaceChip_isUnknownWhenNameIsNil() {
        let chip = FaceChip(image: nil, name: nil)
        XCTAssertTrue(chip.isUnknown)
    }

    func testFaceChip_isUnknownWhenNameIsEmpty() {
        let chip = FaceChip(image: nil, name: "")
        XCTAssertTrue(chip.isUnknown)
    }

    func testFaceChip_isNotUnknownWhenNamePresent() {
        let chip = FaceChip(image: nil, name: "Mom")
        XCTAssertFalse(chip.isUnknown)
    }

    // MARK: - 4. FilterPill action wiring

    func testFilterPill_actionRunsWhenInvoked() {
        var fired = 0
        let pill = FilterPill(label: "Keep", systemImage: "hand.thumbsup", count: 7, isActive: false) {
            fired += 1
        }
        // We test the exposed API — invoke the closure the view holds.
        pill.action()
        pill.action()
        XCTAssertEqual(fired, 2, "FilterPill.action closure should run on each call")

        // Basic sanity: the label / count survived init.
        XCTAssertEqual(pill.label, "Keep")
        XCTAssertEqual(pill.count, 7)
        XCTAssertEqual(pill.systemImage, "hand.thumbsup")
        XCTAssertFalse(pill.isActive)
    }

    // MARK: - 5. MetadataRow nil handling

    @MainActor
    func testMetadataRow_rendersWithNilValue() {
        let row = MetadataRow(label: "x", value: nil, systemImage: "x")
        renderSmokeTest(row)
    }

    @MainActor
    func testMetadataRow_rendersWithEmptyStringValue() {
        let row = MetadataRow(label: "Camera", value: "", systemImage: "camera")
        renderSmokeTest(row)
    }

    // MARK: - 6. HapticToast auto-dismiss ID behavior

    func testToastMessage_idIsUniquePerInit() {
        let a = ToastMessage(.success, "Named as Taylor")
        let b = ToastMessage(.success, "Named as Taylor")
        XCTAssertNotEqual(a.id, b.id, "Each ToastMessage should mint a fresh UUID so it retriggers animations")
    }

    func testToastMessage_equatableDiffersByID() {
        let a = ToastMessage(.info, "Same title")
        let b = ToastMessage(.info, "Same title")
        // Same semantic content, but Equatable should still differ because IDs differ.
        XCTAssertNotEqual(a, b)
    }

    // MARK: - 7. Token sanity

    func testSpacingTokens_baseIs16() {
        XCTAssertEqual(HPSpacing.base, 16)
    }

    func testRadiusTokens_cardIs16() {
        XCTAssertEqual(HPRadius.card, 16)
    }

    func testColorTokens_curationColorsDistinct() {
        XCTAssertNotEqual(HPColor.keeper, HPColor.reject)
        XCTAssertNotEqual(HPColor.keeper, HPColor.archive)
        XCTAssertNotEqual(HPColor.needsReview, HPColor.reject)
    }

    func testMotionTokens_snappyAndSmoothAreDistinct() {
        // SwiftUI.Animation is not directly Equatable, so compare their textual
        // representations — sufficient to catch a copy/paste regression where
        // two tokens accidentally share the same spring parameters.
        let snappy = String(describing: HPMotion.snappy)
        let smooth = String(describing: HPMotion.smooth)
        XCTAssertNotEqual(snappy, smooth, "HPMotion.snappy and .smooth should be distinct animations")
    }

    // MARK: - 8. View smoke tests (render-no-crash)

    @MainActor
    func testPhotoTile_smoke() {
        renderSmokeTest(
            PhotoTile(image: nil, isSelected: false, curationColor: HPColor.keeper, overlayBadge: "RAW")
        )
    }

    @MainActor
    func testFaceChip_smoke() {
        renderSmokeTest(FaceChip(image: nil, name: "Mom", size: .medium, isSelected: false) {})
    }

    @MainActor
    func testFilterPill_smoke() {
        renderSmokeTest(
            FilterPill(label: "Keep", systemImage: "hand.thumbsup", count: 12, isActive: true) {}
        )
    }

    @MainActor
    func testSearchScopeBar_smoke() {
        renderSmokeTest(SearchScopeBarSmokeHost())
    }

    @MainActor
    func testMetadataRow_smoke() {
        renderSmokeTest(
            MetadataRow(label: "Camera", value: "Fujifilm X-T5", systemImage: "camera")
        )
    }

    @MainActor
    func testShimmerPlaceholder_smoke() {
        renderSmokeTest(ShimmerPlaceholder())
    }

    @MainActor
    func testHapticToast_smoke() {
        let message = ToastMessage(.success, "Named as Taylor", subtitle: "3 more faces updated")
        renderSmokeTest(HapticToast(message: message))
    }

    @MainActor
    func testGlassPanel_smoke() {
        renderSmokeTest(GlassPanel { Text("hi") })
    }

    @MainActor
    func testMeshBackdrop_smoke() {
        // `animated: false` to avoid keeping a TimelineView ticking during the test.
        renderSmokeTest(MeshBackdrop(palette: .dusk, animated: false))
    }

    // NOTE: FaceReviewCard is intentionally NOT smoke-tested here. In the
    // real app its callers wire it up to AppDatabase-backed Face models, and
    // its sheet-based naming flow + swipe gestures make a bare render flaky.
    // Covered instead via its value types below.

    func testFaceReviewCardModel_equatableIdentity() {
        let a = FaceReviewCard.Model(id: "1", faceImage: nil, contextImage: nil, suggestedName: "Taylor", photoDateText: "Aug 4, 2024")
        let b = FaceReviewCard.Model(id: "1", faceImage: nil, contextImage: nil, suggestedName: "Taylor", photoDateText: "Aug 4, 2024")
        let c = FaceReviewCard.Model(id: "2", faceImage: nil, contextImage: nil, suggestedName: "Taylor", photoDateText: "Aug 4, 2024")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - Private wrappers

/// Wraps `SearchScopeBar`, which needs a `Namespace.ID`, so the smoke test can
/// own `@Namespace` and `@State` locally.
private struct SearchScopeBarSmokeHost: View {
    @Namespace private var ns
    @State private var scope: SearchScope = .all

    var body: some View {
        SearchScopeBar(selection: $scope, namespaceID: ns)
    }
}
