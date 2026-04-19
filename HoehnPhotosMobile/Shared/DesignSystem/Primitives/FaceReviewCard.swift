import SwiftUI
#if canImport(Pow)
import Pow
#endif

struct FaceReviewCard: View {
    struct Model: Identifiable, Equatable {
        let id: String
        var faceImage: UIImage?
        var contextImage: UIImage?
        var suggestedName: String?
        var photoDateText: String?
    }

    enum Action {
        case name(String)
        case reject
        case merge
    }

    let model: Model
    var onAction: (Action) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var swipedAway: Bool = false
    @State private var showingNameSheet: Bool = false
    @State private var draftName: String = ""

    private let threshold: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let ctx = model.contextImage {
                    Image(uiImage: ctx)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 22)
                        .overlay(.black.opacity(0.25))
                } else {
                    MeshBackdrop(palette: .dusk, animated: false)
                }

                VStack(spacing: HPSpacing.base) {
                    Spacer(minLength: 0)
                    FaceChip(image: model.faceImage, name: nil, size: .large, isSelected: true) {}
                        .padding(.top, HPSpacing.xl)

                    if let date = model.photoDateText {
                        Text(date)
                            .font(HPFont.cardSubtitle)
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    GlassPanel(tone: .overlay, cornerRadius: HPRadius.card) {
                        VStack(spacing: HPSpacing.sm) {
                            Text("Who is this?")
                                .font(HPFont.sectionHeader)
                            if let suggested = model.suggestedName {
                                Text("Suggested: \(suggested)")
                                    .font(HPFont.cardSubtitle)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: HPSpacing.sm) {
                                Button {
                                    HPHaptic.medium()
                                    swipe(.merge, geo: geo)
                                } label: {
                                    Label("Merge", systemImage: "person.2.crop.square.stack")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(HPColor.archive)

                                Button {
                                    HPHaptic.medium()
                                    swipe(.reject, geo: geo)
                                } label: {
                                    Label("Not a person", systemImage: "xmark")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(HPColor.reject)

                                Button {
                                    HPHaptic.medium()
                                    draftName = model.suggestedName ?? ""
                                    showingNameSheet = true
                                } label: {
                                    Label("Name", systemImage: "pencil")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(HPColor.keeper)
                            }
                            .labelStyle(.titleAndIcon)
                        }
                        .padding(HPSpacing.base)
                    }
                    .padding(.horizontal, HPSpacing.base)
                    .padding(.bottom, HPSpacing.base)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HPRadius.card, style: .continuous))
            .overlay(directionHint(geo: geo))
            .rotationEffect(.degrees(Double(dragOffset.width / 20)))
            .offset(dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { g in dragOffset = g.translation }
                    .onEnded { g in
                        if g.translation.width > threshold {
                            draftName = model.suggestedName ?? ""
                            showingNameSheet = true
                            withAnimation(HPMotion.smooth) { dragOffset = .zero }
                        } else if g.translation.width < -threshold {
                            swipe(.reject, geo: geo)
                        } else if g.translation.height < -threshold {
                            swipe(.merge, geo: geo)
                        } else {
                            withAnimation(HPMotion.smooth) { dragOffset = .zero }
                        }
                    }
            )
            #if canImport(Pow)
            .conditionalEffect(.pushDown, condition: abs(dragOffset.width) > 40 || dragOffset.height < -40)
            #endif
        }
        .aspectRatio(0.72, contentMode: .fit)
        .sheet(isPresented: $showingNameSheet) {
            nameSheet
                .presentationDetents([.height(260)])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func directionHint(geo: GeometryProxy) -> some View {
        let dx = dragOffset.width
        let dy = dragOffset.height

        HStack {
            if dx > 20 {
                hintPill("Name", icon: "pencil", color: HPColor.keeper, strength: Double(dx / threshold))
                Spacer()
            } else if dx < -20 {
                Spacer()
                hintPill("Reject", icon: "xmark", color: HPColor.reject, strength: Double(-dx / threshold))
            } else {
                Spacer()
            }
        }
        .padding(HPSpacing.base)
        .overlay(alignment: .top) {
            if dy < -20 {
                hintPill("Merge", icon: "person.2", color: HPColor.archive, strength: Double(-dy / threshold))
                    .padding(.top, HPSpacing.base)
            }
        }
    }

    private func hintPill(_ label: String, icon: String, color: Color, strength: Double) -> some View {
        HStack(spacing: HPSpacing.xs) {
            Image(systemName: icon)
            Text(label).font(HPFont.chipLabelActive)
        }
        .padding(.horizontal, HPSpacing.md)
        .padding(.vertical, HPSpacing.sm)
        .foregroundStyle(.white)
        .background(Capsule().fill(color.opacity(min(1, strength))))
        .scaleEffect(min(1.2, 0.9 + strength * 0.35))
    }

    private func swipe(_ action: Action, geo: GeometryProxy) {
        withAnimation(HPMotion.bouncy) {
            switch action {
            case .reject: dragOffset = CGSize(width: -geo.size.width * 1.4, height: 0)
            case .merge: dragOffset = CGSize(width: 0, height: -geo.size.height * 1.4)
            case .name: dragOffset = CGSize(width: geo.size.width * 1.4, height: 0)
            }
            swipedAway = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onAction(action)
        }
    }

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: HPSpacing.base) {
            Text("Name this face")
                .font(HPFont.sectionHeader)
            TextField("e.g. Taylor", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { submitName() }
            HStack {
                Button("Cancel") {
                    showingNameSheet = false
                }
                Spacer()
                Button("Save") { submitName() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(HPSpacing.lg)
    }

    private func submitName() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showingNameSheet = false
        HPHaptic.medium()
        onAction(.name(name))
    }
}

#Preview("Review Card") {
    struct Demo: View {
        @State var actions: [String] = []
        @State var idx = 0
        let models: [FaceReviewCard.Model] = [
            .init(id: "1", faceImage: nil, contextImage: nil, suggestedName: "Taylor", photoDateText: "Aug 4, 2024"),
            .init(id: "2", faceImage: nil, contextImage: nil, suggestedName: nil, photoDateText: "Dec 12, 2023"),
            .init(id: "3", faceImage: nil, contextImage: nil, suggestedName: "Alex", photoDateText: "May 22, 2025")
        ]
        var body: some View {
            VStack(spacing: HPSpacing.base) {
                if idx < models.count {
                    FaceReviewCard(model: models[idx]) { action in
                        switch action {
                        case .name(let n): actions.append("Named \(models[idx].id) → \(n)")
                        case .reject: actions.append("Rejected \(models[idx].id)")
                        case .merge: actions.append("Merge \(models[idx].id)")
                        }
                        idx += 1
                    }
                    .padding(HPSpacing.lg)
                } else {
                    Text("All caught up ✨").font(HPFont.screenTitle)
                }
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(actions, id: \.self) { Text($0).font(HPFont.cardSubtitle) }
                    }
                    .padding()
                }
            }
        }
    }
    return Demo()
}
