import SwiftUI

/// Full-space placeholder for offline, unauthenticated, or error dashboard states.
struct StatusMessageView: View {
    let systemImage: String
    let title: String
    let message: String
    var retryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let retryAction {
                Button("Try Again", action: retryAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Offline") {
    StatusMessageView(
        systemImage: "wifi.slash",
        title: "You're Offline",
        message: "Connect to the internet to see the latest vehicle status.",
        retryAction: {}
    )
}

#Preview("Error") {
    StatusMessageView(
        systemImage: "exclamationmark.triangle.fill",
        title: "Something Went Wrong",
        message: "Tesla Fleet API returned HTTP 500: server exploded",
        retryAction: {}
    )
}
