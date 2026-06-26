import SwiftUI

/// First-launch entry point. Two paths: generate a brand-new Nostr
/// identity, or import an existing local-signing identity by pasting an nsec.
struct WelcomeView: View {
    @State private var showCreate = false
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    VStack(spacing: 12) {
                        Image("WnLogo")
                            .accessibilityHidden(true)

                        Text("White Noise")
                            .font(.largeTitle.weight(.semibold))
                    }

                    Text("End-to-end encrypted group messaging.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 14) {
                    Button {
                        showCreate = true
                    } label: {
                        Text("Create New Identity")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        showImport = true
                    } label: {
                        Text("Import Existing nsec")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationDestination(isPresented: $showCreate) {
                CreateIdentityView()
            }
            .navigationDestination(isPresented: $showImport) {
                ImportIdentityView()
            }
        }
    }
}
