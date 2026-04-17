import Foundation
import Combine

// MARK: - MediumPreset

struct MediumPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let params: MediumParams
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, params: MediumParams, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.params = params
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - PresetManager

@MainActor
class PresetManager: ObservableObject {
    @Published var customPresets: [MediumPreset] = []

    private let presetsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("StudioPresets", isDirectory: true)
    }()

    init() {
        loadCustomPresets()
    }

    // MARK: - Public API

    /// Returns built-in + custom presets filtered to the given medium.
    func presets(for medium: ArtMedium) -> [MediumPreset] {
        let builtIn = Self.builtInPresets.filter { $0.params.medium == medium }
        let custom = customPresets.filter { $0.params.medium == medium }
        return builtIn + custom
    }

    func saveCustomPreset(_ preset: MediumPreset) {
        // Replace if same ID already exists
        if let idx = customPresets.firstIndex(where: { $0.id == preset.id }) {
            customPresets[idx] = preset
        } else {
            customPresets.append(preset)
        }
        persistCustomPresets()
    }

    func deleteCustomPreset(id: UUID) {
        customPresets.removeAll { $0.id == id }
        persistCustomPresets()
    }

    // MARK: - Persistence

    private var presetsFileURL: URL {
        presetsDirectory.appendingPathComponent("custom-presets.json")
    }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: presetsDirectory.path) {
            try? fm.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        }
    }

    private func persistCustomPresets() {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(customPresets) else { return }
        try? data.write(to: presetsFileURL, options: .atomic)
    }

    private func loadCustomPresets() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: presetsFileURL.path),
              let data = try? Data(contentsOf: presetsFileURL),
              let decoded = try? JSONDecoder().decode([MediumPreset].self, from: data)
        else { return }
        customPresets = decoded
    }

    // MARK: - Built-in Presets (3 per medium)

    static let builtInPresets: [MediumPreset] = {
        var presets: [MediumPreset] = []

        // -- Oil Painting --
        presets.append(MediumPreset(
            name: "Rich Impasto",
            params: .oil(OilPaintPipeline.Params(
                numColors: 8, bilateralD: 20, sigmaColor: 40, sigmaSpace: 120,
                pruneMinPixels: 100, brushTexture: 0.9
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Smooth Blend",
            params: .oil(OilPaintPipeline.Params(
                numColors: 16, bilateralD: 15, sigmaColor: 100, sigmaSpace: 80,
                pruneMinPixels: 200, brushTexture: 0.3
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Flat Poster",
            params: .oil(OilPaintPipeline.Params(
                numColors: 6, bilateralD: 10, sigmaColor: 30, sigmaSpace: 50,
                pruneMinPixels: 400, brushTexture: 0.1
            )),
            isBuiltIn: true
        ))

        // -- Watercolor --
        presets.append(MediumPreset(
            name: "Wet-on-Wet",
            params: .watercolor(WatercolorPipeline.Params(
                numColors: 5, washIntensity: 0.9, bleedAmount: 12, paperWetness: 0.7
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Dry Brush",
            params: .watercolor(WatercolorPipeline.Params(
                numColors: 10, washIntensity: 0.3, bleedAmount: 3, paperWetness: 0.2
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Delicate",
            params: .watercolor(WatercolorPipeline.Params(
                numColors: 12, washIntensity: 0.5, bleedAmount: 6, paperWetness: 0.4
            )),
            isBuiltIn: true
        ))

        // -- Charcoal --
        presets.append(MediumPreset(
            name: "Bold Shadows",
            params: .charcoal(CharcoalPipeline.Params(
                blurRadius: 15, thresholds: [15, 40, 80, 140],
                contrast: 180, paperRoughness: 0.8, smudgeAmount: 12
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Soft Study",
            params: .charcoal(CharcoalPipeline.Params(
                blurRadius: 30, thresholds: [30, 70, 120, 170],
                contrast: 100, paperRoughness: 0.4, smudgeAmount: 6
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "High Contrast",
            params: .charcoal(CharcoalPipeline.Params(
                blurRadius: 8, thresholds: [10, 30, 60, 130],
                contrast: 200, paperRoughness: 0.9, smudgeAmount: 4
            )),
            isBuiltIn: true
        ))

        // -- Trois Crayon --
        presets.append(MediumPreset(
            name: "Classic",
            params: .troisCrayon(TroisCrayonPipeline.defaultParams),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Warm",
            params: .troisCrayon(TroisCrayonPipeline.Params(
                blurRadius: 25, thresholds: [55, 125, 185],
                sanguineColor: TroisCrayonPipeline.RGBColor(r: 185, g: 50, b: 30),
                paperColor: TroisCrayonPipeline.RGBColor(r: 200, g: 182, b: 158),
                contrast: 140
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Subtle",
            params: .troisCrayon(TroisCrayonPipeline.Params(
                blurRadius: 30, thresholds: [50, 120, 200],
                sanguineColor: TroisCrayonPipeline.RGBColor(r: 165, g: 65, b: 38),
                paperColor: TroisCrayonPipeline.RGBColor(r: 194, g: 179, b: 158),
                contrast: 90
            )),
            isBuiltIn: true
        ))

        // -- Graphite --
        presets.append(MediumPreset(
            name: "Technical",
            params: .graphite(GraphitePipeline.Params(
                blurRadius: 15, thresholds: [40, 90, 145, 200],
                contrast: 140, paperTexture: 0.15, noiseStrength: 3, sharpAmount: 2.0
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Soft Sketch",
            params: .graphite(GraphitePipeline.Params(
                blurRadius: 38, thresholds: [55, 110, 160, 210],
                contrast: 110, paperTexture: 0.4, noiseStrength: 14, sharpAmount: 0.4
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Detailed",
            params: .graphite(GraphitePipeline.Params(
                blurRadius: 22, thresholds: [45, 95, 150, 205],
                contrast: 150, paperTexture: 0.25, noiseStrength: 6, sharpAmount: 2.2
            )),
            isBuiltIn: true
        ))

        // -- Ink Wash --
        presets.append(MediumPreset(
            name: "Sumi-e",
            params: .inkWash(InkWashPipeline.Params(
                numBands: 5, blurAmount: 4, edgeStrength: 0.7, inkDensity: 0.7
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Loose Wash",
            params: .inkWash(InkWashPipeline.Params(
                numBands: 4, blurAmount: 10, edgeStrength: 0.25, inkDensity: 0.5
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Precise",
            params: .inkWash(InkWashPipeline.Params(
                numBands: 8, blurAmount: 2, edgeStrength: 0.8, inkDensity: 0.65
            )),
            isBuiltIn: true
        ))

        // -- Pastel --
        presets.append(MediumPreset(
            name: "Vivid",
            params: .pastel(PastelPipeline.Params(
                numColors: 14, softness: 1.5, saturation: 1.8, textureGrain: 0.8
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Muted",
            params: .pastel(PastelPipeline.Params(
                numColors: 12, softness: 6, saturation: 0.8, textureGrain: 0.25
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Impressionist",
            params: .pastel(PastelPipeline.Params(
                numColors: 8, softness: 3.5, saturation: 1.3, textureGrain: 0.5
            )),
            isBuiltIn: true
        ))

        // -- Pen & Ink --
        presets.append(MediumPreset(
            name: "Fine Detail",
            params: .penAndInk(PenAndInkPipeline.Params(
                edgeSensitivity: 0.25, lineWeight: 0.5, contrast: 1.4
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Bold Lines",
            params: .penAndInk(PenAndInkPipeline.Params(
                edgeSensitivity: 0.7, lineWeight: 2.2, contrast: 1.8
            )),
            isBuiltIn: true
        ))
        presets.append(MediumPreset(
            name: "Contour",
            params: .penAndInk(PenAndInkPipeline.Params(
                edgeSensitivity: 0.5, lineWeight: 1.2, contrast: 1.5
            )),
            isBuiltIn: true
        ))

        return presets
    }()
}
