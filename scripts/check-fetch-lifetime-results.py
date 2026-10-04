#!/usr/bin/env python3
"""Require actual successful lifetime regressions in xcresulttool's test tree."""
import json
import sys


MAX_INPUT_BYTES = 8 * 1024 * 1024
REQUIRED = frozenset(
    "PinnedHTTPSFetchLifetimeTests/" + name + "()"
    for name in (
        "nativePublicHTTPSFetchUsesDefaultTransport",
        "gateRemembersCancellationBeforeInstallation",
        "gateDeliversOnlyOneOfConcurrentCompletions",
        "absoluteAttemptExpiryCannotSlidePastTotalDeadline",
        "blockedDNSCancellationReturnsBeforeWorkerRelease",
        "blockedDNSDeadlineReturnsBeforeWorkerReleaseAndDoesNotConnect",
        "sixAbandonedDNSWorkersRetainTheirSlotsUntilTheyActuallyExit",
        "resolverFailureReleasesItsReservation",
        "endpointFallbackBeyondTwelveSecondsUsesRemainingTotalBudget",
        "successfulResolutionFreesItsSlotBeforeSequentialRedirects",
        "redirectsAndEndpointsNeverResetTotalBudget",
    )
) | {"RemoteImageLoaderTests/avatarDrainFinishesWhileCancelledDNSWorkerIsStillBlocked()"}


def require_passes(document):
    if not isinstance(document, dict) or not isinstance(document.get("testNodes"), list):
        raise ValueError("Missing xcresult test tree")
    results = {identifier: [] for identifier in REQUIRED}
    pending = list(document["testNodes"])
    while pending:
        node = pending.pop()
        if not isinstance(node, dict):
            raise ValueError("Invalid xcresult test node")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "")
            parts = identifier.split("/") if isinstance(identifier, str) else []
            if len(parts) >= 2:
                suite = parts[-2].removeprefix("whitenoise_iosTests.")
                key = suite + "/" + parts[-1]
                if key in results:
                    results[key].append(node.get("result"))
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("Invalid xcresult test children")
        pending.extend(children)
    refused = sorted(key for key, values in results.items() if not values or any(value != "Passed" for value in values))
    if refused:
        raise ValueError("Required tests missing or not passed: " + ", ".join(refused))
    return sorted(results)


def main():
    try:
        payload = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(payload) > MAX_INPUT_BYTES:
            raise ValueError("xcresult test tree exceeds input limit")
        identifiers = require_passes(json.loads(payload))
    except (ValueError, UnicodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    for identifier in identifiers:
        print("Verified lifetime regression PASS: " + identifier)
    print(f"Verified all {len(identifiers)} required lifetime regressions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
