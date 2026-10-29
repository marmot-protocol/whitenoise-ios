// Temporary lint canary for #1242 (reverted next).
#if DEBUG
var debugCanaryForTesting = 0
#endif
func forTestingCanaryPrefix() {}
var canaryReady = true // canaryCommentForTesting
let canaryText = #"raw "canaryRawForTesting" text"#
// reason: canary exception
// swiftlint:disable:next no_test_hook_in_app_code
var canaryAllowedForTesting = 0
