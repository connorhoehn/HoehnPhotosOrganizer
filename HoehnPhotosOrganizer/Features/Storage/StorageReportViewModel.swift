import Foundation
import SwiftUI
import Combine

@MainActor
final class StorageReportViewModel: ObservableObject {
    @Published var report: StorageReport?
    @Published var consolidationPlan: ConsolidationPlan?
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Consolidation planner inputs
    @Published var sourceDriveLabel: String = ""
    @Published var targetDriveLabel: String = ""
    @Published var showPlanPreview = false

    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func loadReport() async {
        isLoading = true
        errorMessage = nil
        do {
            report = try await StorageReportService(db: db).generateReport()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func generateConsolidationPlan() async {
        guard !sourceDriveLabel.isEmpty, !targetDriveLabel.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let planService = ConsolidationPlanService(db: db)
            consolidationPlan = try await planService.generatePlan(
                sourceDriveLabel: sourceDriveLabel,
                targetDriveLabel: targetDriveLabel
            )
            showPlanPreview = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
