import SwiftUI

extension View {
    /// Share the conversation's gradual fade with a little extra room below it.
    func wnFadingHeader() -> some View {
        padding(.bottom, 4)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Color(.systemBackground), location: 0),
                        .init(color: Color(.systemBackground).opacity(0.94), location: 0.58),
                        .init(color: Color(.systemBackground).opacity(0.68), location: 0.82),
                        .init(color: Color(.systemBackground).opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
    }
}
