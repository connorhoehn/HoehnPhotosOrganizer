import SwiftUI

struct PrintOutcomeComparisonView: View {
    let sourceImage: NSImage?
    let outcomeImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Print Outcome Comparison")
                .font(.headline)

            HStack(spacing: 16) {
                // Source photo
                VStack(alignment: .center, spacing: 8) {
                    Text("Source Photo")
                        .font(.caption)
                        .fontWeight(.medium)

                    if let image = sourceImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 250)
                            .border(Color.gray.opacity(0.3))
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 250)
                            .overlay {
                                Text("No image")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                    }
                }

                Divider()

                // Outcome photo
                VStack(alignment: .center, spacing: 8) {
                    Text("Print Outcome")
                        .font(.caption)
                        .fontWeight(.medium)

                    if let image = outcomeImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 250)
                            .border(Color.gray.opacity(0.3))
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 250)
                            .overlay {
                                Text("No image captured")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
    }
}

#Preview {
    PrintOutcomeComparisonView(sourceImage: nil, outcomeImage: nil)
}
