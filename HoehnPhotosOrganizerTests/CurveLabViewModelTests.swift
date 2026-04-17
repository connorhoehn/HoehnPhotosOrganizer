// CurveLabViewModelTests.swift
// HoehnPhotosOrganizerTests
//
// Tests for CurveLabViewModel, PrintLabPage, PrintProcess, InkTone,
// QTRCurve, SplitToneConfig, and CurveLabChatMessage models.

import XCTest
import SwiftUI
@testable import HoehnPhotosOrganizer

@MainActor
final class CurveLabViewModelTests: XCTestCase {

    private var vm: CurveLabViewModel!

    override func setUp() {
        super.setUp()
        vm = CurveLabViewModel()
    }

    // MARK: - Initial State

    func test_initialPage_isPrintLayout() {
        XCTAssertEqual(vm.currentPage, .printLayout)
    }

    func test_initialQuadFiles_isEmpty() {
        XCTAssertTrue(vm.quadFiles.isEmpty)
    }

    func test_initialMeasurements_isEmpty() {
        XCTAssertTrue(vm.measurements.isEmpty)
    }

    func test_initialBuilderSteps_isEmpty() {
        XCTAssertTrue(vm.builderSteps.isEmpty)
    }

    func test_initialSmoothingWindow_is5() {
        XCTAssertEqual(vm.smoothingWindow, 5)
    }

    func test_initialSelectedProcess_isPlatinumPd() {
        XCTAssertEqual(vm.selectedProcess, .platinumPd)
    }

    func test_initialSplitTone_disabled() {
        XCTAssertFalse(vm.splitTone.enabled)
    }

    // MARK: - Page Navigation

    func test_setPage_curveBuilder() {
        vm.currentPage = .curveBuilder
        XCTAssertEqual(vm.currentPage, .curveBuilder)
    }

    func test_setPage_allPagesValid() {
        for page in PrintLabPage.allCases {
            vm.currentPage = page
            XCTAssertEqual(vm.currentPage, page)
        }
    }

    // MARK: - Quad File / Measurement Selection

    func test_selectedQuadFile_nil_whenEmpty() {
        XCTAssertNil(vm.selectedQuadFile)
    }

    func test_selectedMeasurement_nil_whenEmpty() {
        XCTAssertNil(vm.selectedMeasurement)
    }

    // MARK: - QTRCurve Model

    func test_qtrCurve_defaultValues() {
        let curve = QTRCurve(name: "Default")
        XCTAssertEqual(curve.name, "Default")
        XCTAssertEqual(curve.fileName, "")
        XCTAssertEqual(curve.process, .inkjetBW)
        XCTAssertEqual(curve.inkTone, .neutral)
        XCTAssertTrue(curve.steps.isEmpty)
        XCTAssertEqual(curve.notes, "")
    }

    func test_qtrCurve_processAssignment() {
        let curve = QTRCurve(name: "Cyano", process: .cyanotype)
        XCTAssertEqual(curve.process, .cyanotype)
    }

    func test_qtrCurve_inkToneColor_warmNotCool() {
        XCTAssertNotEqual(
            InkTone.warm.color.description,
            InkTone.cool.color.description
        )
    }

    // MARK: - PrintProcess Properties

    func test_printProcess_allCasesCount() {
        XCTAssertEqual(PrintProcess.allCases.count, 12)
    }

    func test_printProcess_usesPositiveCurve_inkjetBW() {
        XCTAssertTrue(PrintProcess.inkjetBW.usesPositiveCurve)
    }

    func test_printProcess_usesPositiveCurve_platinumPd() {
        XCTAssertFalse(PrintProcess.platinumPd.usesPositiveCurve)
    }

    func test_printProcess_usesPositiveCurve_inkjetColor() {
        XCTAssertTrue(PrintProcess.inkjetColor.usesPositiveCurve)
    }

    func test_printProcess_allAltProcesses_useNegativeCurve() {
        let altProcesses: [PrintProcess] = [
            .digitalNeg, .platinumPd, .cyanotype, .silverGelatin,
            .saltPrint, .vanDykeBrown, .gumBichromate, .carbonTransfer,
            .directToPlate, .chrysotype
        ]
        for process in altProcesses {
            XCTAssertFalse(process.usesPositiveCurve, "\(process.rawValue) should use negative curve")
        }
    }

    func test_printProcess_allHaveIcons() {
        for process in PrintProcess.allCases {
            XCTAssertFalse(process.icon.isEmpty, "\(process.rawValue) missing icon")
        }
    }

    func test_printProcess_dropCounts_platinumPd() {
        XCTAssertTrue(PrintProcess.platinumPd.typicalDropCounts.contains("drops"))
    }

    func test_printProcess_dropCounts_inkjetBW() {
        XCTAssertEqual(PrintProcess.inkjetBW.typicalDropCounts, "N/A")
    }

    func test_printProcess_dropCounts_silverGelatin() {
        XCTAssertTrue(PrintProcess.silverGelatin.typicalDropCounts.contains("N/A"))
    }

    // MARK: - InkTone

    func test_inkTone_allCases() {
        XCTAssertEqual(InkTone.allCases.count, 4)
        let expected: Set<InkTone> = [.warm, .neutral, .cool, .custom]
        XCTAssertEqual(Set(InkTone.allCases), expected)
    }

    func test_inkTone_colors_allDifferent() {
        let descriptions = InkTone.allCases.map { $0.color.description }
        XCTAssertEqual(descriptions.count, Set(descriptions).count,
                       "Each InkTone should have a distinct color")
    }

    func test_inkTone_rawValues() {
        XCTAssertEqual(InkTone.warm.rawValue, "Warm")
        XCTAssertEqual(InkTone.neutral.rawValue, "Neutral")
        XCTAssertEqual(InkTone.cool.rawValue, "Cool")
        XCTAssertEqual(InkTone.custom.rawValue, "Custom")
    }

    // MARK: - SplitToneConfig

    func test_splitToneConfig_default_allZero() {
        let config = SplitToneConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.curve1Highlights, 0)
        XCTAssertEqual(config.curve1Midtones, 0)
        XCTAssertEqual(config.curve1Shadows, 0)
        XCTAssertEqual(config.curve2Highlights, 0)
        XCTAssertEqual(config.curve2Midtones, 0)
        XCTAssertEqual(config.curve2Shadows, 0)
        XCTAssertEqual(config.curve3Highlights, 0)
        XCTAssertEqual(config.curve3Midtones, 0)
        XCTAssertEqual(config.curve3Shadows, 0)
    }

    func test_splitToneConfig_equatable() {
        let a = SplitToneConfig()
        let b = SplitToneConfig()
        XCTAssertEqual(a, b)
    }

    func test_splitToneConfig_notEqual_whenModified() {
        var a = SplitToneConfig()
        let b = SplitToneConfig()
        a.curve1Highlights = 50
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Builder State

    func test_builderTargetImage_nilByDefault() {
        XCTAssertNil(vm.builderTargetImage)
    }

    func test_builderSteps_canBeSet() {
        let steps = (0..<21).map { i in
            CurveStep(input: Double(i) / 20.0, output: Double(i) / 20.0)
        }
        vm.builderSteps = steps
        XCTAssertEqual(vm.builderSteps.count, 21)
    }

    // MARK: - Chat Messages

    func test_chatMessages_initiallyEmpty() {
        XCTAssertTrue(vm.chatMessages.isEmpty)
    }

    func test_chatMessage_roles() {
        let user = CurveLabChatMessage(role: .user, text: "Hello")
        let assistant = CurveLabChatMessage(role: .assistant, text: "Hi there")
        let system = CurveLabChatMessage(role: .system, text: "System message")
        XCTAssertEqual(user.role.rawValue, "user")
        XCTAssertEqual(assistant.role.rawValue, "assistant")
        XCTAssertEqual(system.role.rawValue, "system")
    }

    func test_chatMessage_hasTimestamp() {
        let before = Date()
        let msg = CurveLabChatMessage(role: .user, text: "Test")
        let after = Date()
        XCTAssertGreaterThanOrEqual(msg.timestamp, before)
        XCTAssertLessThanOrEqual(msg.timestamp, after)
    }

    func test_chatMessage_hasUniqueIDs() {
        let a = CurveLabChatMessage(role: .user, text: "A")
        let b = CurveLabChatMessage(role: .user, text: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - PrintLabPage

    func test_printLabPage_allCases_4Pages() {
        XCTAssertEqual(PrintLabPage.allCases.count, 4)
    }

    func test_printLabPage_icons_allNonEmpty() {
        for page in PrintLabPage.allCases {
            XCTAssertFalse(page.icon.isEmpty, "\(page.rawValue) missing icon")
        }
    }

    func test_printLabPage_rawValues_readable() {
        let expected = ["Print Layout", "Curves", "Processes", "Printers"]
        let actual = PrintLabPage.allCases.map(\.rawValue)
        XCTAssertEqual(actual, expected)
    }

    func test_printLabPage_identifiable() {
        for page in PrintLabPage.allCases {
            XCTAssertEqual(page.id, page.rawValue)
        }
    }

    // MARK: - Quad File Selection

    func test_selectedQuadFile_matchesID() {
        let quad = QTRQuadFile(
            fileName: "test.quad",
            comments: [],
            channels: (0..<8).map { i in
                InkChannel(name: QTRFileParser.standardChannelNames[i],
                          values: Array(repeating: UInt16(0), count: 256))
            }
        )
        vm.quadFiles = [quad]
        vm.selectedQuadFileID = quad.id
        XCTAssertEqual(vm.selectedQuadFile?.fileName, "test.quad")
    }

    // MARK: - Measurement Selection

    func test_selectedMeasurement_matchesID() {
        let meas = SpyderPRINTMeasurement(
            fileName: "test.txt",
            steps: [LabStep(stepNumber: 0, labL: 95, labA: 0, labB: 0)]
        )
        vm.measurements = [meas]
        vm.selectedMeasurementID = meas.id
        XCTAssertEqual(vm.selectedMeasurement?.fileName, "test.txt")
    }

    // MARK: - Loading State

    func test_isLoadingFiles_defaultFalse() {
        XCTAssertFalse(vm.isLoadingFiles)
    }

    func test_loadFilesError_defaultNil() {
        XCTAssertNil(vm.loadFilesError)
    }
}
