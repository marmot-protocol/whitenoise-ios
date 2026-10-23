import Testing

/// Tier tags read by `scripts/audit/inventory.py --emit-tier-lists`. They mark
/// a suite's cost class only; traits that change scheduling stay separate.
extension Tag {
    /// Constructs or starts a Marmot runtime (`MarmotClient.testClient()`,
    /// `AppState.test()`), so a test-plan tier can skip or gate it.
    @Tag static var runtime: Self
    /// Hosts a `UIWindow` or `UIHostingController` and depends on real layout.
    @Tag static var uiHosting: Self
}
