import Testing
@testable import whitenoise_ios

/// `UnreadCountBadge` renders a compact count capped at "99+". Locks that
/// boundary without rendering the view.
struct UnreadCountBadgeTests {
    @Test func showsExactCountUpToNinetyNine() {
        #expect(UnreadCountBadge.label(for: 1) == "1")
        #expect(UnreadCountBadge.label(for: 42) == "42")
        #expect(UnreadCountBadge.label(for: 99) == "99")
    }

    @Test func capsAtNinetyNinePlusOnceOverNinetyNine() {
        #expect(UnreadCountBadge.label(for: 100) == "99+")
        #expect(UnreadCountBadge.label(for: 1000) == "99+")
        #expect(UnreadCountBadge.label(for: .max) == "99+")
    }
}
