import SwiftUI

/// Animated three-dot typing indicator — dots pulse in sequence like a chat "is typing..." state.
struct TypingDotsView: View {
    @State private var activeIndex = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.purple.opacity(i == activeIndex ? 0.9 : 0.25))
                    .frame(width: 7, height: 7)
                    .scaleEffect(i == activeIndex ? 1.15 : 0.75)
                    .animation(.easeInOut(duration: 0.3), value: activeIndex)
            }
        }
        .frame(height: 22)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                activeIndex = (activeIndex + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
