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
RU_FORMS = {"one": "%lld", "few": "%lld", "many": "%lld", "other": "%lld"}


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(forms, substitution=False, arg=1, spec="lld"):
    variations = {"plural": {name: unit(value) for name, value in forms.items()}}
    if substitution:
        return {**unit("%#@count@"), "substitutions": {
            "count": {"argNum": arg, "formatSpecifier": spec, "variations": variations},
        }}
    return {"variations": variations}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings}


class FixtureCase(unittest.TestCase):
    """Name-keyed tables are emptied so fixtures exercise one rule at a time."""

    TABLES = ("REQUIRED_KEYS", "REQUIRED_PLURAL_KEYS", "PLURAL_GAPS", "PINNED_VALUES", "ONCE_ENGLISH_KEYS",
              "SHARED_SPELLINGS", "SHARED_FORMS", "INFOPLIST_REQUIRED_KEYS", "INFOPLIST_PINNED_VALUES")

    def setUp(self):
        for name in self.TABLES:
            table = getattr(CHECK, name)
            self.addCleanup(setattr, CHECK, name, table)
            setattr(CHECK, name, {dict: {}, frozenset: frozenset()}.get(type(table), ()))

    def errors(self, strings):
        return CHECK.check_strings_catalog(catalog(strings), locales=LOCALES)


class FormatParsingTests(unittest.TestCase):
    def test_positions_types_and_tokens(self):
        self.assertEqual(CHECK.parse_format("%@ of %lld, %2$@ %1$lld 100%% %#@count@ %02lld"),
                         ([(1, "@"), (1, "lld"), (2, "@"), (2, "lld"), (3, "lld")], ["count"]))

    def test_prose_percent_is_not_a_specifier(self):
        self.assertEqual(CHECK.parse_format("50 % de remise"), ([], []))


class StringsCatalogTests(FixtureCase):
    def test_complete_catalog_passes(self):
        self.assertEqual(self.errors({
            "Settings": {"localizations": {"de": unit("Einstellungen"), "ru": unit("Настройки")}},
            "%@ of %lld": {"localizations": {"de": unit("%2$lld von %1$@"), "ru": unit("%@ из %lld")}},
            "%lld members": {"localizations": {
                "en": plural({"one": "%lld member", "other": "%lld members"}),
                "de": plural({"one": "%lld Mitglied", "other": "%lld Mitglieder"}, substitution=True),
                "ru": plural(RU_FORMS),
            }},
            "": {"localizations": {"de": unit(""), "ru": unit("")}},
        }), [])

    def test_missing_locale_fails(self):
        errors = self.errors({"Settings": {"localizations": {"de": unit("Einstellungen")}}})
        self.assertEqual(errors, ["ru: missing localization for 'Settings'"])

    def test_untranslated_plural_form_fails(self):
        entry = {"localizations": {"de": plural({"one": "%lld", "other": "%lld"}), "ru": plural(RU_FORMS)}}
        entry["localizations"]["de"]["variations"]["plural"]["other"]["stringUnit"]["state"] = "needs_review"
        self.assertIn("de [other]: '%lld members' is not translated (state: needs_review)",
                      self.errors({"%lld members": entry}))

    def test_empty_value_and_missing_specifier_fail(self):
        errors = self.errors({"Draft: %@": {"localizations": {"de": unit("  "), "ru": unit("Черновик")}}})
        self.assertIn("de: empty value for 'Draft: %@'", errors)
        self.assertIn("ru: specifiers [] for 'Draft: %@' expect ['%1$@']", errors)

    def test_specifier_multiset_counts_duplicates(self):
        errors = self.errors({"%@ and %@": {"localizations": {"de": unit("%@ und %@"), "ru": unit("%@ и")}}})
        self.assertEqual(errors, ["ru: specifiers ['%1$@'] for '%@ and %@' expect ['%1$@', '%2$@']"])

    def test_positional_type_swap_fails(self):
        errors = self.errors({"%@ of %lld": {"localizations": {
            "de": unit("%2$lld von %1$@"), "ru": unit("%1$lld из %2$@"),
        }}})
        self.assertEqual(errors, ["ru: specifiers ['%1$lld', '%2$@'] for '%@ of %lld' expect ['%1$@', '%2$lld']"])

    def test_substitution_token_without_definition_fails(self):
        localization = plural({"other": "%lld"}, substitution=True)
        localization["stringUnit"]["value"] = "%#@counter@"
        errors = self.errors({"%lld votes": {"localizations": {"de": localization, "ru": plural(RU_FORMS)}}})
        self.assertIn("de: '%lld votes' uses %#@counter@ without a substitution", errors)
        self.assertIn("de: '%lld votes' defines substitution 'count' its value never uses", errors)

    def test_substitution_argument_must_match_the_key(self):
        errors = self.errors({"%lld votes": {"localizations": {
            "de": plural({"other": "%lld"}, substitution=True, spec="@"),
            "ru": plural(RU_FORMS, substitution=True, arg=2),
        }}})
        self.assertIn("de: specifiers ['%1$@'] for '%lld votes' expect ['%1$lld']", errors)
        self.assertIn("ru: specifiers ['%2$lld'] for '%lld votes' expect ['%1$lld']", errors)
        self.assertIn("de count [other]: substitution 'count' form carries ['lld'], expects ['@'] for '%lld votes'",
                      errors)

    def test_substitution_form_must_carry_its_specifier(self):
        errors = self.errors({"%lld votes": {"localizations": {
            "de": plural({"one": "Eine Stimme", "other": "%lld Stimmen"}, substitution=True),
            "ru": plural(RU_FORMS, substitution=True),
        }}})
        self.assertEqual(errors, [
            "de count [one]: substitution 'count' form carries [], expects ['lld'] for '%lld votes'",
        ])

    def test_inferred_count_key_without_plural_in_one_locale_fails(self):
        errors = self.errors({"%lld members": {"localizations": {
            "en": plural({"one": "%lld member", "other": "%lld members"}),
            "de": unit("%lld Mitglieder"),
            "ru": plural(RU_FORMS),
        }}})
        self.assertEqual(errors, ["de: '%lld members' needs plural variations"])

    def test_missing_other_and_russian_categories_fail(self):
        errors = self.errors({"%lld members": {"localizations": {
            "de": plural({"one": "%lld Mitglied"}),
            "ru": plural({"one": "%lld", "other": "%lld"}),
        }}})
        self.assertEqual(errors, [
            "de: '%lld members' is missing an `other` plural form",
            "ru: '%lld members' needs one/few/many/other plural forms",
        ])

    def test_each_substitution_needs_its_own_complete_plural_forms(self):
        def two(first, second):
            return {**unit("%#@a@ %#@b@"), "substitutions": {
                "a": {"argNum": 1, "formatSpecifier": "lld", "variations": {
                    "plural": {name: unit("%lld") for name in first}}},
                "b": {"argNum": 2, "formatSpecifier": "lld", "variations": {
                    "plural": {name: unit("%lld") for name in second}}},
            }}
        errors = self.errors({"%lld of %lld": {"localizations": {
            "de": two(["one", "other"], ["one"]),
            "ru": two(["one", "few"], ["many", "other"]),
        }}})
        self.assertEqual(errors, [
            "de: '%lld of %lld' is missing an `other` plural form",
            "ru: '%lld of %lld' is missing an `other` plural form",
        ])
        errors = self.errors({"%lld of %lld": {"localizations": {
            "de": two(["other"], ["other"]),
            "ru": two(["one", "few", "other"], ["many", "other"]),
        }}})
        self.assertEqual(errors, ["ru: '%lld of %lld' needs one/few/many/other plural forms"])

    def test_required_plural_key_flattened_everywhere_fails(self):
        CHECK.REQUIRED_PLURAL_KEYS = ("%lld members",)
        errors = self.errors({"%lld members": {"localizations": {
            "en": unit("%lld members"), "de": unit("%lld Mitglieder"), "ru": unit("%lld участников"),
        }}})
        self.assertEqual(errors, [f"{locale}: '%lld members' needs plural variations" for locale in ("en", "de", "ru")])
        self.assertEqual(self.errors({}), ["missing required key '%lld members'"])

    def test_plural_gap_is_exempt_until_it_closes(self):
        CHECK.PLURAL_GAPS = frozenset({"Forward %lld messages"})
        gap = {"en": plural({"one": "%lld", "other": "%lld"}), "de": unit("%lld"), "ru": unit("%lld")}
        self.assertEqual(self.errors({"Forward %lld messages": {"localizations": gap}}), [])
        # The exemption covers missing plural dictionaries, not incomplete ones.
        partial = {**gap, "ru": plural({"one": "%lld", "other": "%lld"})}
        self.assertEqual(self.errors({"Forward %lld messages": {"localizations": partial}}),
                         ["ru: 'Forward %lld messages' needs one/few/many/other plural forms"])
        closed = {**gap, "de": plural({"one": "%lld", "other": "%lld"}), "ru": plural(RU_FORMS)}
        self.assertEqual(self.errors({"Forward %lld messages": {"localizations": closed}}),
                         ["remove 'Forward %lld messages' from PLURAL_GAPS: it has plural variations in every locale"])
        self.assertEqual(self.errors({}),
                         ["remove 'Forward %lld messages' from PLURAL_GAPS: the key no longer exists"])

    def test_required_key_must_exist(self):
        CHECK.REQUIRED_KEYS = ("Settings",)
        self.assertEqual(self.errors({}), ["missing required key 'Settings'"])

    def test_pinned_value_must_match(self):
        CHECK.PINNED_VALUES = {"Sign In": {"de": "Anmelden", "ru": "Войти"}}
        errors = self.errors({"Sign In": {"localizations": {"de": unit("Einloggen"), "ru": unit("Войти")}}})
        self.assertEqual(errors, ["de: 'Sign In' is 'Einloggen', pinned 'Anmelden'"])

    def test_once_english_keys_must_exist(self):
        CHECK.REQUIRED_KEYS = ("Off",)
        CHECK.ONCE_ENGLISH_KEYS = ("Off", "Sign Up")
        self.assertEqual(self.errors({}), ["missing required key 'Off'", "missing required key 'Sign Up'"])

    def test_english_copy_fails_unless_shared_spelling(self):
        CHECK.SHARED_SPELLINGS = frozenset({("Minutes", "fr"), ("GIF", "*")})
        errors = CHECK.check_strings_catalog(catalog({
            # Exempt for French only: German left as English still fails.
            "Minutes": {"localizations": {"fr": unit("Minutes"), "de": unit("Minutes")}},
            "GIF": {"localizations": {"fr": unit("GIF"), "de": unit("GIF")}},
            "Off": {"localizations": {"en": unit("Off"), "fr": unit("Off"), "de": unit("Aus")}},
            # Compared with the English value, not the key, and case-sensitively.
            "toggle.off": {"localizations": {"en": unit("Turned off"), "fr": unit("Turned off"),
                                             "de": unit("Turned Off")}},
            # The key's own text fails too: older English wording or a raw identifier.
            "Sign in": {"localizations": {"en": unit("Sign in to White Noise"), "fr": unit("Se connecter"),
                                          "de": unit("Sign in")}},
        }), locales=("de", "fr"))
        self.assertEqual(errors, [
            "de: 'Minutes' still shows the English copy",
            "fr: 'Off' still shows the English copy",
            "de: 'Sign in' still shows the English copy",
            "fr: 'toggle.off' still shows the English copy",
        ])

    def test_english_copy_compares_displayed_text(self):
        CHECK.SHARED_FORMS = {("%lld videos", "it"): frozenset({"%lld video"})}
        errors = CHECK.check_strings_catalog(catalog({
            "%lld videos": {"localizations": {
                "en": plural({"one": "%lld video", "other": "%lld videos"}, substitution=True),
                # Italian "video" is invariable, so it shares English "%lld video": exempt as a form.
                "it": plural({"one": "%lld video", "other": "%lld video"}, substitution=True),
                # English copied into every Russian form, few/many included.
                "ru": plural({"one": "%lld videos", "few": "%lld videos", "many": "%lld videos",
                              "other": "%lld videos"}, substitution=True),
                # Plain variations without a substitution shell, left in English.
                "de": plural({"one": "%lld video", "other": "%lld videos"}),
            }},
            "%lld photos": {"localizations": {
                "en": plural({"one": "%lld photo", "other": "%lld photos"}, substitution=True),
                # Half translated still ships English.
                "it": plural({"one": "%lld foto", "other": "%lld photos"}, substitution=True),
                # A flat string or a renamed substitution against English's plural.
                "ru": unit("%lld photo"),
                "de": {**unit("%#@n@"), "substitutions": {"n": {"argNum": 1, "formatSpecifier": "lld",
                       "variations": {"plural": {"one": unit("%lld photo"), "other": unit("%lld photos")}}}}},
            }},
            "%lld songs": {"localizations": {
                "en": plural({"one": "%lld song", "other": "%lld songs"}, substitution=True),
                "de": plural({"one": "%lld Lied", "other": "%lld Lieder"}, substitution=True),
                "it": plural({"one": "%lld brano", "other": "%lld brani"}, substitution=True),
                "ru": plural({"one": "%lld песня", "few": "%lld песни", "many": "%lld песен",
                              "other": "%lld песни"}, substitution=True),
            }},
            # Format-only copy has no words to translate.
            "%@ · %@": {"localizations": {"de": unit("%@ · %@"), "it": unit("%@ · %@"), "ru": unit("%@ · %@")}},
            # Placeholder numbering doesn't show.
            "Uploads %@ to %@.": {"localizations": {
                "en": unit("Uploads %1$@ to %2$@."), "de": unit("Uploads %@ to %@."),
                "it": unit("Carica %1$@ su %2$@."), "ru": unit("Uploads %2$@ to %1$@."),
            }},
            # Neither does the layout: English fills a shell, German renames it, Italian spells each form out.
            "%lld left": {"localizations": {
                "en": {**unit("%#@count@ left"), "substitutions": {"count": {"argNum": 1, "formatSpecifier": "lld",
                       "variations": {"plural": {"one": unit("%lld"), "other": unit("%lld")}}}}},
                "de": {**unit("%#@n@ left"), "substitutions": {"n": {"argNum": 1, "formatSpecifier": "lld",
                       "variations": {"plural": {"one": unit("%lld"), "other": unit("%lld")}}}}},
                "it": plural({"one": "%lld left", "other": "%lld left"}),
                "ru": {**unit("Осталось %#@n@"), "substitutions": {"n": {"argNum": 1, "formatSpecifier": "lld",
                       "variations": {"plural": {"one": unit("%lld"), "few": unit("%lld"), "many": unit("%lld"),
                                                 "other": unit("%lld")}}}}},
            }},
            # A flat English value that isn't its key is the English copy.
            "files.count": {"localizations": {
                "en": unit("%lld files"), "de": plural({"one": "%lld files", "other": "%lld files"}),
                "it": unit("%lld file"), "ru": unit("%lld файлов"),
            }},
        }), locales=("de", "it", "ru"))
        self.assertEqual([error for error in errors if "English copy" in error], [
            "de: '%lld left' still shows the English copy",
            "it: '%lld left' still shows the English copy",
            "de: '%lld photos' still shows the English copy",
            "it: '%lld photos' still shows the English copy",
            "ru: '%lld photos' still shows the English copy",
            "de: '%lld videos' still shows the English copy",
            "ru: '%lld videos' still shows the English copy",
            "de: 'Uploads %@ to %@.' still shows the English copy",
            "ru: 'Uploads %@ to %@.' still shows the English copy",
            "de: 'files.count' still shows the English copy",
        ])

    def test_english_counts_inside_a_translated_sentence_fail(self):
        def left(shell, one, other):
            return {**unit(shell), "substitutions": {"c": {"argNum": 1, "formatSpecifier": "lld",
                    "variations": {"plural": {"one": unit(one), "other": unit(other)}}}}}
        errors = CHECK.check_strings_catalog(catalog({"%lld files left": {"localizations": {
            "en": left("%#@c@ left", "%lld file", "%lld files"),
            "de": left("Noch %#@c@", "%lld file", "%lld files"),
            "it": left("Ancora %#@c@", "%1$lld file", "%1$lld files"),
            "ru": plural({"one": "Остался %lld файл", "few": "Осталось %lld файла", "many": "Осталось %lld файлов",
                          "other": "Осталось %lld файла"}),
        }}}), locales=("de", "it", "ru"))
        self.assertEqual([error for error in errors if "English copy" in error], [
            "de: '%lld files left' still shows the English copy",
            "it: '%lld files left' still shows the English copy",
        ])

    def test_english_copy_fills_every_substitution(self):
        def forms(files, folders, files_name="files"):
            return {**unit(f"%#@{files_name}@ and %#@folders@"), "substitutions": {
                files_name: {"argNum": 1, "formatSpecifier": "lld",
                             "variations": {"plural": {k: unit(v) for k, v in files.items()}}},
                "folders": {"argNum": 2, "formatSpecifier": "lld",
                            "variations": {"plural": {k: unit(v) for k, v in folders.items()}}},
            }}
        english_files = {"one": "%lld file", "other": "%lld files"}
        english_folders = {"one": "%lld folder", "other": "%lld folders"}
        errors = CHECK.check_strings_catalog(catalog({"%lld files and %lld folders": {"localizations": {
            "en": forms(english_files, english_folders),
            # Folder forms that happen to spell English file forms: a different argument, not English.
            "it": forms({"one": "%lld documento", "other": "%lld documenti"}, english_files),
            # English throughout: few/many render like English `other`.
            "ru": forms({"one": "%lld file", "few": "%lld files", "many": "%lld files", "other": "%lld files"},
                        {"one": "%lld folder", "few": "%lld folders", "many": "%lld folders",
                         "other": "%lld folders"}),
            # Renaming a substitution changes nothing shown.
            "de": forms(english_files, english_folders, files_name="dateien"),
        }}}), locales=("de", "it", "ru"))
        def counts(shell):
            return {**unit(shell), "substitutions": {
                name: {"argNum": arg, "formatSpecifier": "lld", "variations": {"plural": {
                    "one": unit("%lld"), "other": unit("%lld")}}} for arg, name in ((1, "a"), (2, "b"))}}
        errors += self.errors({"search.found": {"localizations": {
            "en": counts("Found %#@a@ files in %#@b@ folders"),
            # Matches only once both English counts are filled in.
            "de": unit("Found %lld files in %lld folders"),
            "ru": counts("Найдено файлов: %#@a@, папок: %#@b@"),
        }}})
        self.assertEqual([error for error in errors if "English copy" in error], [
            "de: '%lld files and %lld folders' still shows the English copy",
            "ru: '%lld files and %lld folders' still shows the English copy",
            "de: 'search.found' still shows the English copy",
        ])

    def test_shared_spelling_that_no_longer_applies_fails(self):
        CHECK.SHARED_SPELLINGS = frozenset({
            ("Minutes", "de"), ("GIF", "*"), ("Gone", "ru"), ("Minutes", "fr"), ("Spam", "*"), ("Spam", "pt-BR"),
        })
        errors = self.errors({
            "Minutes": {"localizations": {"de": unit("Minuten"), "ru": unit("Минуты")}},
            "GIF": {"localizations": {"de": unit("GIF-Datei"), "ru": unit("ГИФ")}},
            # Still English in one checked locale (not the first), so the exemption stands.
            "Spam": {"localizations": {"de": unit("Spam-Nachricht"), "ru": unit("Spam")}},
        })
        self.assertEqual(errors, [
            "remove ('GIF', '*') from SHARED_SPELLINGS: no locale shows it as English",
            "remove ('Gone', 'ru') from SHARED_SPELLINGS: no locale shows it as English",
            "remove ('Minutes', 'de') from SHARED_SPELLINGS: no locale shows it as English",
            "('Spam', 'pt-BR') in SHARED_SPELLINGS names a locale that does not ship",
        ])

    def test_shared_form_covers_only_that_form(self):
        CHECK.SHARED_FORMS = {("%lld videos", "ru"): frozenset({"%lld video"}),
                              ("%lld videos", "de"): frozenset({"%lld video"}),
                              ("%lld videos", "pt-BR"): frozenset({"%lld video"})}
        english = plural({"one": "%lld video", "other": "%lld videos"}, substitution=True)
        errors = self.errors({"%lld videos": {"localizations": {
            "en": english,
            # English copied whole: the shared singular doesn't cover "videos".
            "ru": plural({"one": "%lld video", "few": "%lld videos", "many": "%lld videos", "other": "%lld videos"},
                         substitution=True),
            # Translated now, so the shared form is stale.
            "de": plural({"one": "%lld Video", "other": "%lld Videos"}, substitution=True),
        }}})
        self.assertEqual(errors, [
            "ru: '%lld videos' still shows the English copy",
            "remove '%lld video' from SHARED_FORMS[('%lld videos', 'de')]: de no longer shows it",
            "('%lld videos', 'pt-BR') in SHARED_FORMS names a locale that does not ship",
        ])


class InfoPlistCatalogTests(FixtureCase):
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

    def test_required_key_and_pinned_value(self):
        CHECK.INFOPLIST_REQUIRED_KEYS = ("CFBundleName",)
        CHECK.INFOPLIST_PINNED_VALUES = {"NSCameraUsageDescription": {"en": "Camera"}}
        errors = self.errors({"NSCameraUsageDescription": {"localizations": {
            "en": unit("Kamera"), "de": unit("Kamera"), "ru": unit("Камера"),
        }}})
        self.assertEqual(errors, [
            "missing required InfoPlist key CFBundleName",
            "en: NSCameraUsageDescription is 'Kamera', pinned 'Camera'",
        ])


class RepositoryCatalogTests(unittest.TestCase):
    """The committed catalogs pass; deliberately broken copies fail."""

    def setUp(self):
        self.shared = json.loads((ROOT / "Shared/Localizable.xcstrings").read_text(encoding="utf-8"))
        self.infoplist = json.loads((ROOT / "whitenoise-ios/InfoPlist.xcstrings").read_text(encoding="utf-8"))

    def broken(self, mutate):
        shared = copy.deepcopy(self.shared)
        mutate(shared["strings"])
        return CHECK.check_strings_catalog(shared)

    def test_repository_catalogs_pass(self):
        self.assertEqual(CHECK.check_repo(ROOT), [])

    def test_flattening_a_required_count_key_fails(self):
        def flatten(strings):
            for localization in strings["%lld members"]["localizations"].values():
                localization.pop("substitutions", None)
                localization.pop("variations", None)
                localization["stringUnit"] = {"state": "translated", "value": "%lld"}
        errors = self.broken(flatten)
        self.assertIn("en: '%lld members' needs plural variations", errors)
        self.assertIn("de: '%lld members' needs plural variations", errors)

    def test_removing_a_required_key_fails(self):
        self.assertIn("missing required key 'Leave “%@”?'", self.broken(lambda s: s.pop("Leave “%@”?")))

    def test_sign_in_as_english_copy_fails(self):
        def english(strings):
            strings["Sign In"]["localizations"]["de"]["stringUnit"]["value"] = "Sign In"
        errors = self.broken(english)
        self.assertIn("de: 'Sign In' is 'Sign In', pinned 'Anmelden'", errors)

    def test_any_key_left_as_english_copy_fails(self):
        def english(strings):
            strings["Playback speed"]["localizations"]["tr"]["stringUnit"]["value"] = "Playback speed"
        self.assertIn("tr: 'Playback speed' still shows the English copy", self.broken(english))

    def test_specifier_type_swap_in_a_real_entry_fails(self):
        def swap(strings):
            strings["%1$lld of %2$lld"]["localizations"]["de"]["stringUnit"]["value"] = "%1$lld von %2$@"
        self.assertIn("de: specifiers ['%1$lld', '%2$@'] for '%1$lld of %2$lld' expect ['%1$lld', '%2$lld']",
                      self.broken(swap))

    def test_broken_russian_plural_and_missing_locale_fail(self):
        def damage(strings):
            strings["%lld members"]["localizations"]["ru"]["substitutions"]["count"]["variations"]["plural"].pop("few")
            del strings["Settings"]["localizations"]["fr"]
        errors = self.broken(damage)
        self.assertIn("ru: '%lld members' needs one/few/many/other plural forms", errors)
        self.assertIn("fr: missing localization for 'Settings'", errors)

    def test_broken_infoplist_catalog_fails(self):
        broken = copy.deepcopy(self.infoplist)
        broken["strings"]["NSMicrophoneUsageDescription"]["localizations"]["tr"]["stringUnit"]["value"] = ""
        del broken["strings"]["CFBundleName"]
        self.assertEqual(CHECK.check_infoplist_catalog(broken), [
            "missing required InfoPlist key CFBundleName",
            "tr: empty InfoPlist value for NSMicrophoneUsageDescription",
        ])


if __name__ == "__main__":
    unittest.main()
