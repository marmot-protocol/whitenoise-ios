import Testing

/// Tier tags read by `scripts/audit/inventory.py --emit-tier-lists`. They mark
/// a suite's cost class only; traits that change scheduling stay separate.
extension Tag {
    /// Constructs or starts a Marmot runtime (`MarmotClient.testClient()`,
    /// `MarmotClient(rootPath:)`, or `bootstrap()`/`startRuntime()`), so a
    /// test-plan tier can skip or gate it. `AppState.test()` without a client
    /// builds no runtime until bootstrap and does not qualify on its own.
    @Tag static var runtime: Self
    /// Hosts a `UIWindow` or `UIHostingController` and depends on real layout.
    @Tag static var uiHosting: Self
}
