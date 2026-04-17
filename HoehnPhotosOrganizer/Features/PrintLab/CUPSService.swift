import Foundation
import AppKit

// MARK: - QTRPrintAttributes

/// QuadToneRIP printer attributes parsed from CUPS/IPP or PPD files.
struct QTRPrintAttributes {
    var curveName: String?
    var colorModel: String?
    var resolution: String?
    var inkLimit: String?
    var ditherAlgorithm: String?
    var feedMode: String?
    var blackInk: String?

    var isEmpty: Bool {
        curveName == nil && colorModel == nil && resolution == nil &&
        inkLimit == nil && ditherAlgorithm == nil && feedMode == nil && blackInk == nil
    }

    static let empty = QTRPrintAttributes()
}

// MARK: - Models

struct CUPSPrinterInfo: Identifiable {
    let id: String           // queue name
    let name: String
    let makeModel: String
    let deviceURI: String
    var state: PrinterState
    var stateMessage: String
    let isDefault: Bool
    let isQTR: Bool
    let isScanner: Bool
    let ppdPath: String?
    var queuedJobCount: Int
    var inkLevels: [InkLevel]
    var ppdOptions: [PPDOption]
    var availableCurves: [String]

    enum PrinterState: String {
        case idle, processing, stopped, unknown
    }

    struct InkLevel: Identifiable {
        let id: String
        let name: String
        let level: Int       // 0-100
        let color: String    // hex color
    }

    struct PPDOption: Identifiable {
        var id: String { keyword }
        let keyword: String
        let text: String
        let defaultChoice: String
        let choices: [(keyword: String, text: String)]
    }
}

struct CUPSJobInfo: Identifiable {
    let id: Int32
    let printerName: String
    let title: String
    let user: String
    let state: JobState
    let stateMessage: String
    let size: Int32
    let createdAt: Date
    let completedAt: Date?
    let progressPercent: Int
    let pagesCompleted: Int
    let totalPages: Int
    let copies: Int
    let mediaSize: String
    let curveName: String?
    let colorModel: String?
    let resolution: String?
    let inkLimit: String?
    let ditherAlgorithm: String?
    let feedMode: String?
    let blackInk: String?
    let appName: String?

    enum JobState: String {
        case pending, held, processing, stopped, canceled, aborted, completed, unknown
    }
}

// MARK: - CUPSService

/// Queries macOS CUPS for printer info, job status, and QTR-specific attributes.
actor CUPSService {

    static let shared = CUPSService()

    /// Cache of QTR attributes for jobs we've seen while active, keyed by CUPS job ID.
    /// When a job transitions to completed, CUPS drops its IPP attributes, so we serve
    /// cached values instead. The cache is bounded to the last 500 jobs to avoid unbounded growth.
    private var qtrAttributeCache: [Int32: QTRPrintAttributes] = [:]
    private let maxCacheSize = 500

    // MARK: - Printers (full load — call once, not on poll)

    func fetchPrinters() -> [CUPSPrinterInfo] {
        var destsPtr: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests(&destsPtr)
        defer { cupsFreeDests(count, destsPtr) }

        guard let dests = destsPtr, count > 0 else { return [] }

        var results: [CUPSPrinterInfo] = []
        for i in 0..<Int(count) {
            let dest = dests[i]
            let name = String(cString: dest.name)
            let isDefault = dest.is_default != 0

            let makeModel = getOption("printer-make-and-model", dest: dest) ?? "Unknown"
            let deviceURI = getOption("device-uri", dest: dest) ?? ""
            let (state, stateMsg) = fetchPrinterState(printerName: name)
            let queuedStr = getOption("queued-job-count", dest: dest) ?? "0"

            let isQTR = makeModel.lowercased().contains("quadtonerip")
            let nameLower = name.lowercased()
            let modelLower = makeModel.lowercased()
            let uriLower = deviceURI.lowercased()
            let isScanner = nameLower.contains("scanner") || nameLower.contains("perfection")
                || modelLower.contains("scanner") || modelLower.contains("perfection")
                || uriLower.contains("scanner") || uriLower.hasPrefix("escl:")
                || uriLower.hasPrefix("ipp://") && uriLower.contains("scan")

            let candidatePath = "/etc/cups/ppd/\(name).ppd"
            let ppdPath = FileManager.default.fileExists(atPath: candidatePath) ? candidatePath : nil

            let inkLevels = fetchInkLevelsViaIPP(printerName: name)
            let ppdOptions = ppdPath != nil ? parsePPDFile(path: ppdPath!, qtrOnly: isQTR) : []

            let availableCurves: [String]
            if isQTR, let curveOpt = ppdOptions.first(where: { $0.keyword == "ripCurve1" }) {
                availableCurves = curveOpt.choices.map(\.keyword).filter { $0 != "-" }
            } else {
                availableCurves = []
            }

            results.append(CUPSPrinterInfo(
                id: name,
                name: name,
                makeModel: makeModel,
                deviceURI: deviceURI,
                state: state,
                stateMessage: stateMsg,
                isDefault: isDefault,
                isQTR: isQTR,
                isScanner: isScanner,
                ppdPath: ppdPath,
                queuedJobCount: Int(queuedStr) ?? 0,
                inkLevels: inkLevels,
                ppdOptions: ppdOptions,
                availableCurves: availableCurves
            ))
        }
        return results
    }

    // MARK: - Lightweight printer state refresh (safe to poll)

    func refreshPrinterStates(printers: [CUPSPrinterInfo], refreshInk: Bool = false) -> [CUPSPrinterInfo] {
        printers.map { printer in
            var updated = printer
            let (state, msg) = fetchPrinterState(printerName: printer.id)
            updated.state = state
            updated.stateMessage = msg
            // Refresh ink when actively printing OR on the periodic ink-refresh tick
            if state == .processing || refreshInk {
                updated.inkLevels = fetchInkLevelsViaIPP(printerName: printer.id)
            }
            return updated
        }
    }

    // MARK: - Jobs

    func fetchActiveJobs(printerName: String? = nil) -> [CUPSJobInfo] {
        fetchJobs(printerName: printerName, whichJobs: 0, enrichWithIPP: true)
    }

    func fetchCompletedJobs(printerName: String? = nil) -> [CUPSJobInfo] {
        fetchJobs(printerName: printerName, whichJobs: 1, enrichWithIPP: false)
    }

    private func fetchJobs(printerName: String?, whichJobs: Int32, enrichWithIPP: Bool) -> [CUPSJobInfo] {
        var jobsPtr: UnsafeMutablePointer<cups_job_t>?
        let count = cupsGetJobs(&jobsPtr, printerName, 0, whichJobs)
        defer { cupsFreeJobs(count, jobsPtr) }

        guard let jobs = jobsPtr, count > 0 else { return [] }

        var results: [CUPSJobInfo] = []
        for i in 0..<Int(count) {
            results.append(buildJobInfo(jobs[i], enrichWithIPP: enrichWithIPP))
        }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - CUPS Logs

    func fetchRecentLogs(lineCount: Int = 200) -> String {
        let logPaths = [
            "/var/log/cups/access_log",
            "/var/log/cups/error_log"
        ]
        var combined = ""
        for path in logPaths {
            guard let tail = tailFile(path: path, lines: lineCount / 2) else { continue }
            combined += "=== \(URL(fileURLWithPath: path).lastPathComponent) ===\n"
            combined += tail
            combined += "\n\n"
        }
        return combined
    }

    // MARK: - QTR Attribute Capture

    /// Fetch QTR-specific attributes from the most recently submitted job on the given printer.
    /// Called immediately after a print dialog completes to capture PPD options before the job finishes.
    /// Falls back to PPD defaults if no active job is found (e.g. job already completed by the time we query).
    func captureQTRAttributes(printerName: String) -> QTRPrintAttributes {
        // Try active jobs first — the just-submitted job should still be in the queue
        var jobsPtr: UnsafeMutablePointer<cups_job_t>?
        let count = cupsGetJobs(&jobsPtr, printerName, 0, 0 /* active */)
        defer { cupsFreeJobs(count, jobsPtr) }

        if let jobs = jobsPtr, count > 0 {
            // Pick the most recently created job (highest creation_time)
            var newest = jobs[0]
            for i in 1..<Int(count) {
                if jobs[i].creation_time > newest.creation_time {
                    newest = jobs[i]
                }
            }
            let attrs = fetchJobAttributesViaIPP(printerName: printerName, jobId: newest.id)
            let result = QTRPrintAttributes(
                curveName: attrs["ripCurve1"],
                colorModel: attrs["ColorModel"],
                resolution: attrs["Resolution"],
                inkLimit: attrs["ripLimit"],
                ditherAlgorithm: attrs["stpDither"],
                feedMode: attrs["ripFeed"],
                blackInk: attrs["ripBlack"]
            )
            if !result.isEmpty { return result }
        }

        // Fallback: read PPD defaults for this printer
        let candidatePath = "/etc/cups/ppd/\(printerName).ppd"
        guard FileManager.default.fileExists(atPath: candidatePath) else {
            return .empty
        }
        let options = parsePPDFile(path: candidatePath, qtrOnly: true)
        return QTRPrintAttributes(
            curveName: options.first(where: { $0.keyword == "ripCurve1" })?.defaultChoice,
            colorModel: options.first(where: { $0.keyword == "ColorModel" })?.defaultChoice,
            resolution: options.first(where: { $0.keyword == "Resolution" })?.defaultChoice,
            inkLimit: options.first(where: { $0.keyword == "ripLimit" })?.defaultChoice,
            ditherAlgorithm: options.first(where: { $0.keyword == "stpDither" })?.defaultChoice,
            feedMode: options.first(where: { $0.keyword == "ripFeed" })?.defaultChoice,
            blackInk: options.first(where: { $0.keyword == "ripBlack" })?.defaultChoice
        )
    }

    // MARK: - Private Helpers

    private func getOption(_ key: String, dest: cups_dest_t) -> String? {
        guard let val = cupsGetOption(key, dest.num_options, dest.options) else { return nil }
        return String(cString: val)
    }

    private func fetchPrinterState(printerName: String) -> (CUPSPrinterInfo.PrinterState, String) {
        let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES)
        let uri = "ipp://localhost:631/printers/\(printerName)"
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, uri)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", nil,
                     "printer-state,printer-state-message,queued-job-count")

        guard let response = cupsDoRequest(nil, request, "/printers/\(printerName)") else {
            return (.unknown, "")
        }
        defer { ippDelete(response) }

        var state: CUPSPrinterInfo.PrinterState = .unknown
        if let stateAttr = ippFindAttribute(response, "printer-state", IPP_TAG_ZERO) {
            switch ippGetInteger(stateAttr, 0) {
            case 3: state = .idle
            case 4: state = .processing
            case 5: state = .stopped
            default: break
            }
        }

        var msg = ""
        if let msgAttr = ippFindAttribute(response, "printer-state-message", IPP_TAG_ZERO),
           let s = ippGetString(msgAttr, 0, nil) {
            msg = String(cString: s)
        }

        return (state, msg)
    }

    private func buildJobInfo(_ job: cups_job_t, enrichWithIPP: Bool) -> CUPSJobInfo {
        let jobId = job.id
        let printer = String(cString: job.dest)
        let title = String(cString: job.title)
        let user = String(cString: job.user)
        let size = job.size

        let state = mapJobState(job.state)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(job.creation_time))
        let completedAt = job.completed_time > 0
            ? Date(timeIntervalSince1970: TimeInterval(job.completed_time)) : nil

        // Only fire IPP round-trip for active jobs where we need progress/QTR attrs
        let attrs: [String: String]
        if enrichWithIPP {
            attrs = fetchJobAttributesViaIPP(printerName: printer, jobId: jobId)

            // Cache QTR attributes while the job is active so they survive completion
            let qtr = QTRPrintAttributes(
                curveName: attrs["ripCurve1"],
                colorModel: attrs["ColorModel"],
                resolution: attrs["Resolution"],
                inkLimit: attrs["ripLimit"],
                ditherAlgorithm: attrs["stpDither"],
                feedMode: attrs["ripFeed"],
                blackInk: attrs["ripBlack"]
            )
            if !qtr.isEmpty {
                qtrAttributeCache[jobId] = qtr
                // Evict oldest entries if cache exceeds limit
                if qtrAttributeCache.count > maxCacheSize {
                    let sortedKeys = qtrAttributeCache.keys.sorted()
                    for key in sortedKeys.prefix(qtrAttributeCache.count - maxCacheSize) {
                        qtrAttributeCache.removeValue(forKey: key)
                    }
                }
            }
        } else {
            attrs = [:]
        }

        // For completed jobs without IPP data, try the in-memory cache
        let cached = !enrichWithIPP ? qtrAttributeCache[jobId] : nil

        return CUPSJobInfo(
            id: jobId,
            printerName: printer,
            title: title,
            user: user,
            state: state,
            stateMessage: attrs["job-printer-state-message"] ?? "",
            size: size,
            createdAt: createdAt,
            completedAt: completedAt,
            progressPercent: Int(attrs["job-media-progress"] ?? "") ?? 0,
            pagesCompleted: Int(attrs["job-impressions-completed"] ?? "") ?? 0,
            totalPages: Int(attrs["job-impressions"] ?? "") ?? 0,
            copies: Int(attrs["copies"] ?? "") ?? 1,
            mediaSize: attrs["media"] ?? "",
            curveName: attrs["ripCurve1"] ?? cached?.curveName,
            colorModel: attrs["ColorModel"] ?? cached?.colorModel,
            resolution: attrs["Resolution"] ?? cached?.resolution,
            inkLimit: attrs["ripLimit"] ?? cached?.inkLimit,
            ditherAlgorithm: attrs["stpDither"] ?? cached?.ditherAlgorithm,
            feedMode: attrs["ripFeed"] ?? cached?.feedMode,
            blackInk: attrs["ripBlack"] ?? cached?.blackInk,
            appName: attrs["com.apple.print.JobInfo.PMApplicationName"]
        )
    }

    private func mapJobState(_ state: ipp_jstate_t) -> CUPSJobInfo.JobState {
        switch state {
        case IPP_JSTATE_PENDING:    return .pending
        case IPP_JSTATE_HELD:       return .held
        case IPP_JSTATE_PROCESSING: return .processing
        case IPP_JSTATE_STOPPED:    return .stopped
        case IPP_JSTATE_CANCELED:   return .canceled
        case IPP_JSTATE_ABORTED:    return .aborted
        case IPP_JSTATE_COMPLETED:  return .completed
        default:                    return .unknown
        }
    }

    // MARK: - IPP Queries

    private func fetchJobAttributesViaIPP(printerName: String, jobId: Int32) -> [String: String] {
        let request = ippNewRequest(IPP_OP_GET_JOB_ATTRIBUTES)
        let uri = "ipp://localhost:631/printers/\(printerName)"
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, uri)
        ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", jobId)

        guard let response = cupsDoRequest(nil, request, "/") else { return [:] }
        defer { ippDelete(response) }

        var results: [String: String] = [:]
        var attr = ippFirstAttribute(response)
        while let a = attr {
            if let namePtr = ippGetName(a) {
                let name = String(cString: namePtr)
                if let valPtr = ippGetString(a, 0, nil) {
                    results[name] = String(cString: valPtr)
                } else {
                    let intVal = ippGetInteger(a, 0)
                    if intVal != 0 { results[name] = "\(intVal)" }
                }
            }
            attr = ippNextAttribute(response)
        }
        return results
    }

    private func fetchInkLevelsViaIPP(printerName: String) -> [CUPSPrinterInfo.InkLevel] {
        let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES)
        let uri = "ipp://localhost:631/printers/\(printerName)"
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, uri)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", nil,
                     "marker-names,marker-levels,marker-colors")

        guard let response = cupsDoRequest(nil, request, "/printers/\(printerName)") else {
            return []
        }
        defer { ippDelete(response) }

        var names: [String] = []
        var levels: [Int] = []
        var colors: [String] = []

        if let namesAttr = ippFindAttribute(response, "marker-names", IPP_TAG_ZERO) {
            for i in 0..<ippGetCount(namesAttr) {
                if let s = ippGetString(namesAttr, i, nil) {
                    names.append(String(cString: s))
                }
            }
        }
        if let levelsAttr = ippFindAttribute(response, "marker-levels", IPP_TAG_ZERO) {
            for i in 0..<ippGetCount(levelsAttr) {
                levels.append(Int(ippGetInteger(levelsAttr, i)))
            }
        }
        if let colorsAttr = ippFindAttribute(response, "marker-colors", IPP_TAG_ZERO) {
            for i in 0..<ippGetCount(colorsAttr) {
                if let s = ippGetString(colorsAttr, i, nil) {
                    colors.append(String(cString: s))
                } else {
                    colors.append("#808080")
                }
            }
        }

        return names.enumerated().map { i, name in
            CUPSPrinterInfo.InkLevel(
                id: "\(printerName)-ink-\(i)",
                name: name,
                level: i < levels.count ? levels[i] : -1,
                color: i < colors.count ? colors[i] : "#808080"
            )
        }
    }

    // MARK: - PPD Parsing

    /// Parse PPD file directly as text to avoid deprecated ppdOpenFile API.
    private func parsePPDFile(path: String, qtrOnly: Bool) -> [CUPSPrinterInfo.PPDOption] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        let qtrKeywords: Set<String> = [
            "ripCurve1", "ripCurve2", "ripCurve3",
            "ripBlack", "ripFeed", "ripSpeed",
            "ColorModel", "Resolution", "stpDither",
            "MediaType", "PageSize"
        ]

        var options: [String: (text: String, defaultChoice: String, choices: [(String, String)])] = [:]
        var defaults: [String: String] = [:]
        var currentKeyword: String?

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // *OpenUI *keyword/Label: PickOne
            if trimmed.hasPrefix("*OpenUI") {
                let parts = trimmed.dropFirst("*OpenUI ".count)
                let slashIdx = parts.firstIndex(of: "/")
                let colonIdx = parts.firstIndex(of: ":")
                if let si = slashIdx, colonIdx.map({ si < $0 }) ?? true {
                    let kw = String(parts[parts.startIndex..<si])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                    let endIdx = colonIdx ?? parts.endIndex
                    let label = String(parts[parts.index(after: si)..<endIdx])
                        .trimmingCharacters(in: .whitespaces)
                    if !qtrOnly || qtrKeywords.contains(kw) {
                        currentKeyword = kw
                        options[kw] = (text: label, defaultChoice: defaults[kw] ?? "", choices: [])
                    }
                } else {
                    let kw = String(parts.prefix(while: { $0 != ":" && $0 != " " }))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                    if !qtrOnly || qtrKeywords.contains(kw) {
                        currentKeyword = kw
                        options[kw] = (text: kw, defaultChoice: defaults[kw] ?? "", choices: [])
                    }
                }
                continue
            }

            if trimmed.hasPrefix("*CloseUI") {
                currentKeyword = nil
                continue
            }

            // *Default<keyword>: <value> — can appear before or after *OpenUI
            if trimmed.hasPrefix("*Default") {
                let rest = trimmed.dropFirst("*Default".count)
                if let colonIdx = rest.firstIndex(of: ":") {
                    let kw = String(rest[rest.startIndex..<colonIdx])
                    let val = String(rest[rest.index(after: colonIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    defaults[kw] = val
                    if var opt = options[kw] {
                        opt.defaultChoice = val
                        options[kw] = opt
                    }
                }
                continue
            }

            // *keyword choiceKey/Label: "..."  or  *keyword choiceKey: "..."
            if let kw = currentKeyword, trimmed.hasPrefix("*\(kw) ") {
                let rest = trimmed.dropFirst("*\(kw) ".count)
                let colonIdx = rest.firstIndex(of: ":")
                let slashIdx = rest.firstIndex(of: "/")

                let choiceKey: String
                let choiceLabel: String

                // Only treat "/" as a label separator if it appears before ":"
                if let si = slashIdx, let ci = colonIdx, si < ci {
                    choiceKey = String(rest[rest.startIndex..<si])
                    choiceLabel = String(rest[rest.index(after: si)..<ci])
                        .trimmingCharacters(in: .whitespaces)
                } else if let ci = colonIdx {
                    choiceKey = String(rest[rest.startIndex..<ci])
                        .trimmingCharacters(in: .whitespaces)
                    choiceLabel = choiceKey
                } else {
                    continue
                }
                if var opt = options[kw] {
                    opt.choices.append((choiceKey, choiceLabel))
                    options[kw] = opt
                }
            }
        }

        return options.map { kw, opt in
            CUPSPrinterInfo.PPDOption(
                keyword: kw,
                text: opt.text,
                defaultChoice: opt.defaultChoice,
                choices: opt.choices
            )
        }.sorted { $0.keyword < $1.keyword }
    }

    // MARK: - File Utilities

    /// Read the last N lines of a file without loading the entire file.
    private func tailFile(path: String, lines: Int) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // Read up to 64KB from the end — enough for ~200 log lines
        let readSize = min(fileSize, 65536)
        fh.seek(toFileOffset: fileSize - readSize)
        let data = fh.readData(ofLength: Int(readSize))
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let allLines = content.components(separatedBy: "\n")
        let tail = allLines.suffix(lines)
        return tail.joined(separator: "\n")
    }
}
