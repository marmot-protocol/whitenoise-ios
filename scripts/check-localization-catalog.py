#!/usr/bin/env python3
"""Lint the app's string catalogs (Shared/Localizable.xcstrings, whitenoise-ios/InfoPlist.xcstrings).

Checks, for every key of the shared catalog and every shipped locale:
  * a localization exists and every leaf (string unit, plural form,
    substitution form) is marked `translated` with a non-empty value;
  * each leaf keeps the key's placeholder multiset (`%@`, `%lld`, ...);
  * a key that uses plural variations in any locale uses them in every locale
    (source included), with an `other` form and, for Russian, one/few/many;
  * the retention and donation copy is not left as the English source.
For the InfoPlist catalog: every key except CFBundleDisplayName has a non-empty
value in English and every shipped locale, usage descriptions are translated,
and CFBundleDisplayName never carries a translated value (it would hide the
build flavor's display name).
"""

import argparse
import json
import re
import sys
from pathlib import Path

LOCALES = ("de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant")
PLACEHOLDER = re.compile(r"%[@a-zA-Z0-9]+")
RUSSIAN_PLURALS = {"one", "few", "many", "other"}

# Count keys whose translations still use a single string unit rather than
# plural variations. Remove an entry once the catalog gains the variations.
PLURAL_GAPS = frozenset({
    "Delete %lld selected messages?",
    "Forward %lld messages",
})

# Families that once shipped with the English source marked `translated`.
RETENTION_KEYS = (
    "Disappearing messages", "Off", "Messages are kept until you delete them.",
    "Messages are deleted for everyone after the selected time.", "Custom", "Duration", "Unit",
    "Seconds", "Minutes", "Hours", "Days", "Weeks", "Enter a duration between %@ and %@.",
    "Delete older messages?", "Set Timer",
    "This timer also applies to messages already in the chat. Everything older than %@ will be deleted immediately.",
    "Updating disappearing messages…", "Disappearing messages updated", "Couldn't update disappearing messages",
)
DONATION_KEYS = (
    "You’re donating %@ each month to help people communicate freely and privately.",
    "Your monthly payment couldn’t be completed. Please check your payment method to continue your support.",
    "Your monthly donation is scheduled to end. Your support has helped us build tools for private communication.",
    "Payments stop on %@", "Donations are temporarily unavailable. Please try again later.",
    "Use up to two decimal places.", "Enter a valid USD amount.", "Thank you for your commitment",
    "By giving monthly, you help IPF keep building White Noise and tools for free, private communication.",
    "Payments", "Invoice", "Your recent payments:", "See all payments", "Invoice unavailable",
    "Your invoice is still being prepared.", "Your payment succeeded. Please try again later to view the invoice.",
    "Thank you for supporting IPF and White Noise. You’re helping people communicate freely and privately.",
    "Help the Internet Privacy Foundation (IPF), a nonprofit building tools for private communication.",
    "IPF is a 501(c)(3) nonprofit incorporated in Wyoming that builds tools to help people communicate privately. "
    "We develop White Noise and Marmot, the open messaging protocol behind it. Your donation supports this work "
    "and our belief that private conversations should be available to everyone.",
    "Charged monthly until you cancel.", "Monthly donation active", "Cancellation scheduled",
    "Monthly donation overdue", "Next payment: %@", "Thank you for your support",
    "%@ will be donated each month until you cancel.", "A donation is already in progress.",
    "About your donation", "Apple Pay isn't available for this donation.", "Apple Pay unavailable",
    "Custom donation amount in USD", "Custom amount", "Frequency", "IPF General Fund Donation",
    "Manage monthly donation", "Monthly", "Monthly donation to IPF", "One time",
    "The donation couldn't be completed. Please try again.", "The maximum donation is $5,000.",
    "The minimum donation is $1.", "USD", "Donation history access is no longer available on this device.",
    "Your donation history couldn't be loaded. Please try again.", "Recent billing activity",
    "Your monthly donation has not started yet. Check your payment method to complete it.",
    "This monthly donation has ended.",
    "This monthly donation's status is unavailable. Check Stripe to manage it.", "Ended on %@",
    "Monthly donation not yet active", "Monthly donation ended", "Monthly donation status unavailable",
    "Load more", "Paid", "Pending", "Payment failed", "Credited", "Paid outside the app",
    "See all billing activity", "This document isn't available right now. Please try again later.",
    "More billing activity couldn't be loaded. Try again.", "A new donation won't restore earlier payments.",
    "Your donation succeeded, but history couldn't be saved on this device.",
)
ENGLISH_COPY_KEYS = RETENTION_KEYS + DONATION_KEYS
# (key, locale) pairs, or (key, "*"), whose correct translation is spelled like English.
SHARED_SPELLINGS = frozenset({("Minutes", "fr"), ("USD", "*")})


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def plural_forms(localization):
    """Every plural-variation dict of one localization, direct or via substitutions."""
    plurals = []
    variations = localization.get("variations")
    if variations is not None:
        plurals.append(variations.get("plural"))
    for substitution in localization.get("substitutions", {}).values():
        plurals.append(substitution.get("variations", {}).get("plural"))
    return plurals


def leaves(localization):
    """(state, value, is_substitution_shell) for each string unit of one localization."""
    result = []
    unit = localization.get("stringUnit")
    if unit is not None:
        result.append((unit.get("state"), unit.get("value"), bool(localization.get("substitutions"))))
    for plural in plural_forms(localization):
        if not isinstance(plural, dict):
            result.append((None, None, False))
            continue
        for form in plural.values():
            unit = form.get("stringUnit", {})
            result.append((unit.get("state"), unit.get("value"), False))
    return result


def source_value(key, localizations):
    unit = localizations.get("en", {}).get("stringUnit")
    return unit.get("value", key) if unit else key


def check_strings_catalog(catalog, locales=LOCALES):
    errors = []
    strings = catalog.get("strings", {})
    for key, entry in sorted(strings.items()):
        localizations = entry.get("localizations", {})
        expected = placeholders(key)
        for locale in locales:
            localization = localizations.get(locale)
            if localization is None:
                errors.append(f"{locale}: missing localization for {key!r}")
                continue
            values = leaves(localization)
            if key and not any(not shell for _, _, shell in values):
                errors.append(f"{locale}: no value for {key!r}")
            for state, value, shell in values:
                if state != "translated":
                    errors.append(f"{locale}: {key!r} is not translated (state: {state})")
                if value is None:
                    errors.append(f"{locale}: {key!r} has a string unit without a value")
                    continue
                if shell:
                    continue
                if key and not value.strip():
                    errors.append(f"{locale}: empty value for {key!r}")
                if placeholders(value) != expected:
                    errors.append(f"{locale}: placeholders {placeholders(value)} for {key!r} expect {expected}")

        plural_locales = {locale for locale, loc in localizations.items() if plural_forms(loc)}
        if plural_locales and key not in PLURAL_GAPS:
            for locale in ("en", *locales) if "en" in localizations else locales:
                forms = [p for p in plural_forms(localizations.get(locale, {})) if isinstance(p, dict)]
                categories = set().union(*forms) if forms else set()
                if not forms:
                    errors.append(f"{locale}: {key!r} needs plural variations")
                elif "other" not in categories:
                    errors.append(f"{locale}: {key!r} is missing an `other` plural form")
                elif locale == "ru" and not RUSSIAN_PLURALS <= categories:
                    errors.append(f"ru: {key!r} needs one/few/many/other plural forms")

    for key in ENGLISH_COPY_KEYS:
        entry = strings.get(key)
        if entry is None:
            errors.append(f"missing key {key!r}")
            continue
        localizations = entry.get("localizations", {})
        english = source_value(key, localizations)
        for locale in locales:
            if (key, locale) in SHARED_SPELLINGS or (key, "*") in SHARED_SPELLINGS:
                continue
            unit = localizations.get(locale, {}).get("stringUnit", {})
            if unit.get("value") == english:
                errors.append(f"{locale}: {key!r} still shows the English copy")
    return errors


def check_infoplist_catalog(catalog, locales=LOCALES):
    errors = []
    strings = catalog.get("strings", {})
    for key, entry in sorted(strings.items()):
        localizations = entry.get("localizations", {})
        if key == "CFBundleDisplayName":
            for locale, localization in sorted(localizations.items()):
                if localization.get("stringUnit", {}).get("state") == "translated":
                    errors.append(f"{locale}: CFBundleDisplayName must not be translated; "
                                  "it would hide the flavor display name")
            continue
        for locale in ("en", *locales):
            unit = localizations.get(locale, {}).get("stringUnit", {})
            if not (unit.get("value") or "").strip():
                errors.append(f"{locale}: empty InfoPlist value for {key}")
            elif key.endswith("UsageDescription") and locale != "en" and unit.get("state") != "translated":
                errors.append(f"{locale}: {key} is not translated (state: {unit.get('state')})")
    return errors


def check_repo(root):
    shared = json.loads((root / "Shared/Localizable.xcstrings").read_text(encoding="utf-8"))
    infoplist = json.loads((root / "whitenoise-ios/InfoPlist.xcstrings").read_text(encoding="utf-8"))
    return (
        [f"Localizable: {error}" for error in check_strings_catalog(shared)]
        + [f"InfoPlist: {error}" for error in check_infoplist_catalog(infoplist)]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="repository root (default: this script's repository)")
    args = parser.parse_args()
    errors = check_repo(args.root)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(f"{len(errors)} localization catalog problem(s)", file=sys.stderr)
        return 1
    if PLURAL_GAPS:
        print(f"note: {len(PLURAL_GAPS)} count key(s) still lack translated plural variations: "
              + ", ".join(sorted(PLURAL_GAPS)))
    print("Localization catalogs OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
