import SwiftUI

/// A single quick-action tile in the Dashboard's control grid.
struct ControlButton: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
        ControlButton(title: "Unlock", systemImage: "lock.open.fill") {}
        ControlButton(title: "Honk", systemImage: "megaphone.fill") {}
        ControlButton(title: "Flash", systemImage: "lightbulb.fill") {}
        ControlButton(title: "Charge Limit", systemImage: "bolt.fill", isDisabled: true) {}
    }
    .padding()
}
