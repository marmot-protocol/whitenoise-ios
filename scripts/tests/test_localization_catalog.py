"""Exercise the string-catalog lint on fixtures and deliberately broken copies of the real catalogs."""
import copy
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("localization_catalog", ROOT / "scripts/check-localization-catalog.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

LOCALES = ("de", "ru")


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(forms, substitution=False):
    variations = {"plural": {name: unit(value) for name, value in forms.items()}}
    if substitution:
        return {**unit("%#@count@"), "substitutions": {"count": {"variations": variations}}}
    return {"variations": variations}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings}


class StringsCatalogTests(unittest.TestCase):
    def setUp(self):
        # The English-copy families are checked by name; keep them out of the
        # fixtures unless a test opts in.
        self.addCleanup(setattr, CHECK, "ENGLISH_COPY_KEYS", CHECK.ENGLISH_COPY_KEYS)
        CHECK.ENGLISH_COPY_KEYS = ()

    def errors(self, strings):
        return CHECK.check_strings_catalog(catalog(strings), locales=LOCALES)

    def test_complete_catalog_passes(self):
        ru_forms = {"one": "%lld участник", "few": "%lld участника", "many": "%lld участников", "other": "%lld"}
        self.assertEqual(self.errors({
            "Settings": {"localizations": {"de": unit("Einstellungen"), "ru": unit("Настройки")}},
            "Draft: %@": {"localizations": {"de": unit("Entwurf: %@"), "ru": unit("Черновик: %@")}},
            "%lld members": {"localizations": {
                "en": plural({"one": "%lld member", "other": "%lld members"}),
                "de": plural({"one": "%lld Mitglied", "other": "%lld Mitglieder"}, substitution=True),
                "ru": plural(ru_forms),
            }},
            "": {"localizations": {"de": unit(""), "ru": unit("")}},
        }), [])

    def test_missing_locale_fails(self):
        errors = self.errors({"Settings": {"localizations": {"de": unit("Einstellungen")}}})
        self.assertEqual(errors, ["ru: missing localization for 'Settings'"])

    def test_untranslated_plural_form_fails(self):
        entry = {"localizations": {
            "de": plural({"one": "%lld Mitglied", "other": "%lld Mitglieder"}),
            "ru": plural({"one": "%lld", "few": "%lld", "many": "%lld", "other": "%lld"}),
        }}
        entry["localizations"]["de"]["variations"]["plural"]["other"]["stringUnit"]["state"] = "needs_review"
        self.assertIn("de: '%lld members' is not translated (state: needs_review)",
                      self.errors({"%lld members": entry}))

    def test_empty_value_and_broken_placeholder_fail(self):
        errors = self.errors({"Draft: %@": {"localizations": {"de": unit("  "), "ru": unit("Черновик")}}})
        self.assertIn("de: empty value for 'Draft: %@'", errors)
        self.assertIn("ru: placeholders [] for 'Draft: %@' expect ['%@']", errors)

    def test_placeholder_multiset_counts_duplicates(self):
        errors = self.errors({"%@ and %@": {"localizations": {"de": unit("%@ und %@"), "ru": unit("%@ и")}}})
        self.assertEqual(errors, ["ru: placeholders ['%@'] for '%@ and %@' expect ['%@', '%@']"])

    def test_count_key_without_plural_in_one_locale_fails(self):
        errors = self.errors({"%lld members": {"localizations": {
            "en": plural({"one": "%lld member", "other": "%lld members"}),
            "de": unit("%lld Mitglieder"),
            "ru": plural({"one": "%lld", "few": "%lld", "many": "%lld", "other": "%lld"}),
        }}})
        self.assertEqual(errors, ["de: '%lld members' needs plural variations"])

    def test_known_plural_gap_is_exempt(self):
        key = next(iter(CHECK.PLURAL_GAPS))
        self.assertEqual(self.errors({key: {"localizations": {
            "en": plural({"one": "%lld", "other": "%lld"}),
            "de": unit("%lld"),
            "ru": unit("%lld"),
        }}}), [])

    def test_missing_other_and_russian_categories_fail(self):
        errors = self.errors({"%lld members": {"localizations": {
            "de": plural({"one": "%lld Mitglied"}),
            "ru": plural({"one": "%lld", "other": "%lld"}),
        }}})
        self.assertEqual(errors, [
            "de: '%lld members' is missing an `other` plural form",
            "ru: '%lld members' needs one/few/many/other plural forms",
        ])

    def test_english_copy_family_fails_unless_shared_spelling(self):
        CHECK.ENGLISH_COPY_KEYS = ("Minutes", "Off")
        errors = CHECK.check_strings_catalog(catalog({
            "Minutes": {"localizations": {"fr": unit("Minutes"), "de": unit("Minuten")}},
            "Off": {"localizations": {"en": unit("Off"), "fr": unit("Off"), "de": unit("Aus")}},
        }), locales=("de", "fr"))
        self.assertEqual(errors, ["fr: 'Off' still shows the English copy"])


class InfoPlistCatalogTests(unittest.TestCase):
    def errors(self, strings):
        return CHECK.check_infoplist_catalog(catalog(strings), locales=LOCALES)

    def test_complete_catalog_passes(self):
        self.assertEqual(self.errors({
            "CFBundleDisplayName": {"localizations": {"en": unit("White Noise", state="new")}},
            "CFBundleName": {"localizations": {"en": unit("WN", state="new"), "de": unit("WN"), "ru": unit("WN")}},
            "NSCameraUsageDescription": {"localizations": {
                "en": unit("Camera"), "de": unit("Kamera"), "ru": unit("Камера"),
            }},
        }), [])

    def test_translated_display_name_fails(self):
        self.assertEqual(self.errors({"CFBundleDisplayName": {"localizations": {"de": unit("WN")}}}),
                         ["de: CFBundleDisplayName must not be translated; it would hide the flavor display name"])

    def test_empty_or_untranslated_usage_description_fails(self):
        errors = self.errors({"NSCameraUsageDescription": {"localizations": {
            "en": unit("Camera"), "de": unit(""), "ru": unit("Камера", state="new"),
        }}})
        self.assertEqual(errors, [
            "de: empty InfoPlist value for NSCameraUsageDescription",
            "ru: NSCameraUsageDescription is not translated (state: new)",
        ])


class RepositoryCatalogTests(unittest.TestCase):
    """The committed catalogs pass, and a deliberately broken copy fails."""

    def setUp(self):
        self.shared = json.loads((ROOT / "Shared/Localizable.xcstrings").read_text(encoding="utf-8"))
        self.infoplist = json.loads((ROOT / "whitenoise-ios/InfoPlist.xcstrings").read_text(encoding="utf-8"))

    def test_repository_catalogs_pass(self):
        self.assertEqual(CHECK.check_repo(ROOT), [])

    def test_broken_shared_catalog_fails(self):
        broken = copy.deepcopy(self.shared)
        broken["strings"]["Off"]["localizations"]["de"] = unit("Off")
        broken["strings"]["%lld members"]["localizations"]["ru"]["substitutions"]["count"]["variations"]["plural"].pop("few")
        del broken["strings"]["Settings"]["localizations"]["fr"]
        errors = CHECK.check_strings_catalog(broken)
        self.assertIn("de: 'Off' still shows the English copy", errors)
        self.assertIn("ru: '%lld members' needs one/few/many/other plural forms", errors)
        self.assertIn("fr: missing localization for 'Settings'", errors)

    def test_broken_infoplist_catalog_fails(self):
        broken = copy.deepcopy(self.infoplist)
        broken["strings"]["NSMicrophoneUsageDescription"]["localizations"]["tr"]["stringUnit"]["value"] = ""
        self.assertEqual(CHECK.check_infoplist_catalog(broken),
                         ["tr: empty InfoPlist value for NSMicrophoneUsageDescription"])


if __name__ == "__main__":
    unittest.main()
