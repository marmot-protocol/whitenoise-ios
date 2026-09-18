import SwiftUI

/// One row of a `WNDropdown`. Values only, so the rows a screen offers stay a
/// pure decision that can be asserted without rendering the menu.
nonisolated struct WNDropdownItem<Selection: Hashable>: Identifiable, Equatable {
    let id: Selection
    let title: LocalizedStringKey
    let systemImage: String
    var isDestructive = false
}

/// A system dropdown anchored to its own trigger, used where a compact list of
/// destinations reads better than a sheet or an accessory pane.
///
/// Rows keep the order they are given: a menu whose entries reorder themselves
/// by proximity to the trigger would put a different action under the finger
/// depending on where the trigger sits on screen.
struct WNDropdown<Selection: Hashable, Trigger: View>: View {
    let items: [WNDropdownItem<Selection>]
    let onSelect: (Selection) -> Void
    @ViewBuilder let trigger: () -> Trigger

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(role: item.isDestructive ? .destructive : nil) {
                    Haptics.tap()
                    onSelect(item.id)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            trigger()
        }
        .menuOrder(.fixed)
    }
}

#Preview("WNDropdown") {
    WNDropdown(
        items: [
            WNDropdownItem(id: "camera", title: "Camera", systemImage: "camera"),
            WNDropdownItem(id: "files", title: "Files", systemImage: "folder"),
            WNDropdownItem(id: "remove", title: "Remove Photo", systemImage: "trash", isDestructive: true)
        ],
        onSelect: { _ in }
    ) {
        Image(systemName: "plus")
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }
}
