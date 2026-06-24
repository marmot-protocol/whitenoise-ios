import SwiftUI

/// Centered inline row for durable group system events (kind 1210).
struct GroupSystemEventRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
    }
}
