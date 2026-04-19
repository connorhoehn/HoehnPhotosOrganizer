import SwiftUI

enum HPMotion {
    static let snappy: Animation = .spring(response: 0.28, dampingFraction: 0.82)
    static let smooth: Animation = .spring(response: 0.42, dampingFraction: 0.88)
    static let bouncy: Animation = .spring(response: 0.35, dampingFraction: 0.68)
    static let heroZoom: Animation = .spring(response: 0.48, dampingFraction: 0.86)
    static let scopeMorph: Animation = .spring(response: 0.38, dampingFraction: 0.82)
    static let chipPop: Animation = .spring(response: 0.22, dampingFraction: 0.72)
    static let shimmer: Animation = .linear(duration: 1.4).repeatForever(autoreverses: false)
    static let fadeQuick: Animation = .easeOut(duration: 0.16)
    static let fadeSlow: Animation = .easeInOut(duration: 0.28)
}

enum HPTransition {
    static let scaleFade: AnyTransition = .scale(scale: 0.9).combined(with: .opacity)
    static let slideUp: AnyTransition = .move(edge: .bottom).combined(with: .opacity)
    static let morphChip: AnyTransition = .scale(scale: 0.6).combined(with: .opacity)
    static let reviewCardOut: AnyTransition = .asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .offset(y: -200).combined(with: .opacity)
    )
}

enum HPNamespaceID {
    static let photoHero = "photo-hero"
    static let faceReview = "face-review"
    static let searchScope = "search-scope"
}
