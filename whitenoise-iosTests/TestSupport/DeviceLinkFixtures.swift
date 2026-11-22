import Foundation
import MarmotKit

func linkPrompt(_ id: String, _ state: DeviceLinkPromptStateFfi, slot: String? = nil) -> DeviceLinkPromptFfi {
    DeviceLinkPromptFfi(promptId: id, slotIdHex: slot, requestedAt: 1_700_000_000, state: state)
}

func linkCode() -> [DeviceLinkEmojiFfi] {
    ["🐶", "🐱", "🦁", "🐎", "🦄", "🐷", "🐘"].map { DeviceLinkEmojiFfi(emoji: $0, description: "Animal") }
}

func linkedDevice(
    slot: String,
    isThisDevice: Bool = false,
    label: String = "",
    platform: String = "iOS",
    status: LinkedDeviceStatusFfi = .active,
    keepWhileInactive: Bool = false,
    inactive: Bool = false,
    removalPending: Bool = false
) -> LinkedDeviceFfi {
    LinkedDeviceFfi(
        slotIdHex: slot, isThisDevice: isThisDevice, label: label, client: "whitenoise", platform: platform,
        linkedAt: 1_700_000_000, linkedBySlotIdHex: nil, status: status, addToAllChats: true,
        bringHistory: true, keepWhileInactive: keepWhileInactive, lastActiveAt: nil, inactive: inactive,
        removalPending: removalPending
    )
}

func unrecognizedSignIn(
    slot: String,
    beforeThisDevice: Bool = false,
    state: UnrecognizedSignInStateFfi = .prompt
) -> UnrecognizedSignInFfi {
    UnrecognizedSignInFfi(
        slotIdHex: slot, client: "whitenoise", appearedAt: 1_700_000_000, lastSeenAt: 1_700_000_000,
        beforeThisDevice: beforeThisDevice, signedIn: true, state: state, linkedBySlotIdHex: nil,
        previouslyLinkedHere: false
    )
}
