import CoreGraphics

/// Shared edge insets and field metrics for bottom-anchored input chrome.
enum BottomInputChromeLayout {
    /// Inset from the screen sides so pills follow the bottom corner radius.
    static let horizontalInset: CGFloat = 24
    /// Edge inset while the keyboard is open — animates down for a wider field.
    static let keyboardOpenHorizontalInset: CGFloat = 8
    /// Minimal lift above the home indicator — iMessage sits low in the bowl.
    static let bottomInset: CGFloat = 0
    /// Extra breathing room between bottom input chrome and the keyboard.
    static let keyboardInset: CGFloat = 10
    /// Fixed separation between the composer and any keyboard-height surface below it.
    static let composerPaneSpacing: CGFloat = 8
    /// Keeps the final timeline row visually separate from the composer chrome.
    static let timelineComposerSpacing: CGFloat = 10
    static let topInset: CGFloat = 2

    /// Side circles (attach, mic, compose) and minimum pill height.
    static let controlSize: CGFloat = 40
    /// Spacing between side controls and the pill.
    static let rowSpacing: CGFloat = 6
    /// Lifts the attachment menu anchor above the paperclip so the popover clears the button.
    static let attachmentMenuAnchorLift: CGFloat = 8
    static let fieldFontSize: CGFloat = 18
    static let fieldLeadingPadding: CGFloat = 13
    static let fieldVerticalPadding: CGFloat = 9
    static let fieldTrailingPadding: CGFloat = 4
    /// Trailing accessory inside the pill (emoji, dictation mic).
    static let inlineAccessoryWidth: CGFloat = 34
    static let inlineSendSize: CGFloat = 38
    static let inlineSendIconSize: CGFloat = 16
    static let sideControlIconSize: CGFloat = 19
    static let inlineAccessoryIconSize: CGFloat = 18
    static let trailingActionIconSize: CGFloat = 19
    static let inlineEmojiIconSize: CGFloat = 22
}
