@testable import whitenoise_ios

/// Scopes the app language to the calling task. Writing the shared test
/// defaults instead would leak the language into concurrently-running suites
/// (parallel Swift Testing) and intermittently fail English-asserting tests.
func withAppLanguage<T>(_ language: AppLanguage, perform body: () throws -> T) rethrows -> T {
    try AppLanguage.$testCurrentOverride.withValue(language, operation: body)
}
