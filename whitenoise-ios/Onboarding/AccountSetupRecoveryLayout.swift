import SwiftUI

struct AccountSetupRecoveryLayout<Content: View, Actions: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let isBusy: Bool
    var inlineActions = false
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    private var scrollsActions: Bool { inlineActions || dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        Form {
            content()
            if scrollsActions {
                Section {
                    actions()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        }
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WNIconButton(title: onBack == nil ? "Close" : "Back",
                             systemImage: onBack == nil ? "xmark" : "chevron.backward", chrome: .container) {
                    if let onBack { onBack() } else { dismiss() }
                }
                    .disabled(isBusy)
            }
        }
        .modifier(WNOnboardingActionBar(isPresented: !scrollsActions) {
            actions()
                .safeAreaPadding(.horizontal, 16)
                .safeAreaPadding(.bottom)
        })
        .interactiveDismissDisabled(isBusy || onBack != nil)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

struct AccountSetupRecoveryCallout<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var isError = false
    var isLoading = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol) }
            }
            .foregroundStyle(isError && !isLoading ? Color.red : Color.primary)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(isError && !isLoading ? Color.red : Color.primary)
                    .accessibilityAddTraits(.isHeader)
                content()
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .listRowBackground(Color(uiColor: .quaternarySystemFill))
        .wnGroupedCardRow(.only)
    }
}
