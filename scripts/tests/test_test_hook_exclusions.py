"""Exercise the test-hook exclusion check on the real tree and on small fixture trees."""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("test_hook_exclusions", ROOT / "scripts/check-test-hook-exclusions.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

LISTED = "whitenoise-ios/Core/RelativeTime.swift"
OTHER = "whitenoise-ios/Core/ProfileStore.swift"


def entry(path):
    return "    - '(^|/)" + path.replace(".", "\\.").replace("+", "\\+") + "$'"


def config(entries, kinds=("comment", "doccomment", "string"), regex=r"\b(?:\w*ForTesting|forTesting)\w*"):
    lines = [
        "only_rules:",
        "  - custom_rules",
        "custom_rules:",
        "  no_test_hook_in_app_code:",
        '    name: "Test hook in app code"',
        f"    regex: '{regex}'",
        "    excluded:",
        "    - '(^|/)whitenoise-iosTests/'",
        *entries,
        "    excluded_match_kinds:",
        *(f"    - {kind}" for kind in kinds),
        "    severity: error",
        "  next_rule:",
        "    regex: 'x'",
    ]
    return "\n".join(lines) + "\n"


class FixtureCase(unittest.TestCase):
    def tree(self, swiftlint, files):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = pathlib.Path(directory.name)
        (root / ".swiftlint.yml").write_text(swiftlint, encoding="utf-8")
        for relative, source in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        return root

    def problems(self, swiftlint, files):
        try:
            return CHECK.problems(self.tree(swiftlint, files))
        except CHECK.ConfigError as error:
            return [str(error)]

    def assertFlags(self, swiftlint, files, *fragments):
        found = self.problems(swiftlint, files)
        for fragment in fragments:
            self.assertTrue(any(fragment in problem for problem in found), f"{fragment!r} not in {found}")


class RealTreeTests(unittest.TestCase):
    def test_repository_passes(self):
        self.assertEqual(CHECK.problems(ROOT), [])


class ExclusionTests(FixtureCase):
    def test_listed_file_with_a_hook_passes(self):
        self.assertEqual(self.problems(config([entry(LISTED)]), {LISTED: "var nowForTesting: Date?\n"}), [])

    def test_prefix_hook_name_counts(self):
        self.assertEqual(self.problems(config([entry(LISTED)]), {LISTED: "func forTestingReset() {}\n"}), [])

    def test_hook_only_in_comments_or_strings_is_stale(self):
        for source in (
            "// nowForTesting\n/* resetForTesting */\n",
            'let a = "nowForTesting"\nlet b = """\nresetForTesting\n"""\n',
            'let a = #"Removed "nowForTesting" earlier"#\n',
            'let b = #"""\nA """ inside, then resetForTesting\n"""#\n',
        ):
            with self.subTest(source=source):
                self.assertFlags(config([entry(LISTED)]), {LISTED: source}, "has no hook left")

    def test_missing_file(self):
        self.assertFlags(config([entry(LISTED)]), {}, "excluded but missing")

    def test_new_entry_is_rejected(self):
        added = "whitenoise-ios/Core/NewThing.swift"
        self.assertFlags(config([entry(added)]), {added: "func resetForTesting() {}\n"}, "only shrink")

    def test_non_file_entry_is_rejected(self):
        self.assertFlags(config(["    - '(^|/)whitenoise-ios/Core/'"]), {}, "write file exclusions as")

    def test_comment_inside_the_list_does_not_end_it(self):
        entries = [entry(OTHER), "  # remaining files", entry(LISTED)]
        files = {OTHER: "var nowForTesting = 0\n", LISTED: "let now = 0\n"}
        self.assertFlags(config(entries), files, f"{LISTED}: excluded but has no hook left")

    def test_regex_comes_from_the_rule(self):
        swiftlint = config([entry(LISTED)], regex=r"\bneverMatches\b")
        self.assertFlags(swiftlint, {LISTED: "var nowForTesting = 0\n"}, "has no hook left")

    def test_match_kinds_must_match_the_stripping(self):
        swiftlint = config([entry(LISTED)], kinds=("comment", "doccomment"))
        self.assertFlags(swiftlint, {LISTED: "var nowForTesting = 0\n"}, "excluded_match_kinds")

    def test_malformed_lists_fail(self):
        for bad in ('    - "(^|/)Shared/L10n\\.swift$"', "    excluded: []"):
            with self.subTest(line=bad):
                self.assertNotEqual(self.problems(config([bad]), {}), [])


class WholeFileDisableTests(FixtureCase):
    def test_whole_file_disable_is_rejected(self):
        source = "// swiftlint:disable no_test_hook_in_app_code\nvar nowForTesting = 0\n"
        self.assertFlags(config([entry(LISTED)]), {LISTED: "var a = 0 // aForTesting\nvar bForTesting = 0\n",
                                                  "Shared/Thing.swift": source}, "Shared/Thing.swift: disable")

    def test_next_line_disable_is_allowed(self):
        source = "// reason\n// swiftlint:disable:next no_test_hook_in_app_code\nvar nowForTesting = 0\n"
        files = {LISTED: "var nowForTesting = 0\n", "Shared/Thing.swift": source}
        self.assertEqual(self.problems(config([entry(LISTED)]), files), [])


if __name__ == "__main__":
    unittest.main()
