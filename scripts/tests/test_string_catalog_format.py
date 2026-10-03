"""Verify lossless formatting, read-only checks, and Xcode writer compatibility."""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/format-string-catalogs.py"
SPEC = importlib.util.spec_from_file_location("catalog_format", SCRIPT)
FORMAT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FORMAT)


class StringCatalogFormatTests(unittest.TestCase):
    def test_preserves_translations_variations_metadata_and_literal_punctuation(self):
        catalog = {
            "version": "1.1",
            "strings": {
                "未読 %@": {
                    "localizations": {
                        "ar": {"variations": {"plural": {
                            "other": {"stringUnit": {"state": "translated", "value": "%lld رسائل"}},
                            "one": {"stringUnit": {"state": "needs_review", "value": "رسالة"}},
                        }}},
                        "en": {"substitutions": {"count": {
                            "argNum": 1, "formatSpecifier": "lld",
                            "variations": {"plural": {"other": {
                                "stringUnit": {"state": "translated", "value": "%lld messages"}
                            }}},
                        }}},
                    },
                    "comment": 'Keep {} and [] / \\"quotes"\n\t🙂 é e\u0301',
                    "extractionState": "stale",
                    "shouldTranslate": False,
                    "futureMetadata": [None, True, 2, {}, []],
                },
                "Empty": {},
            },
            "sourceLanguage": "en",
        }
        formatted = FORMAT.format_catalog(json.dumps(catalog).encode())
        self.assertEqual(json.loads(formatted), catalog)
        self.assertEqual(FORMAT.format_catalog(formatted), formatted)

    def test_xcode_spacing_order_and_empty_objects(self):
        self.assertEqual(
            FORMAT.format_catalog(b'{"strings":{"z":{},"A":{}},"version":"1.0","sourceLanguage":"en"}'),
            b'{\n  "sourceLanguage" : "en",\n  "strings" : {\n'
            b'    "A" : {\n\n    },\n    "z" : {\n\n    }\n'
            b'  },\n  "version" : "1.0"\n}',
        )

    def test_rejects_duplicate_keys_and_invalid_json(self):
        for raw in [b'{"strings":{"same":{},"same":{}}}', b'{', b'{"value":NaN}', b'{"value":Infinity}']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                FORMAT.format_catalog(raw)

    def run_formatter(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)

    def test_check_is_read_only_and_write_then_check_succeeds(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            original = b'{"strings":{},"sourceLanguage":"en","version":"1.0"}\n'
            path.write_bytes(original)
            result = self.run_formatter("--check", path)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("just format-localizations", result.stderr)
            self.assertEqual(path.read_bytes(), original)
            result = self.run_formatter("--write", path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(path.read_bytes()), json.loads(original))
            self.assertEqual(self.run_formatter("--check", path).returncode, 0)

    def test_invalid_input_does_not_partially_rewrite_catalogs(self):
        with tempfile.TemporaryDirectory() as directory:
            good = Path(directory) / "Good.xcstrings"
            bad = Path(directory) / "Bad.xcstrings"
            original = b'{"strings":{},"version":"1.0","sourceLanguage":"en"}'
            good.write_bytes(original)
            bad.write_bytes(b'{"strings":{"key":{},"key":{}}}')
            result = self.run_formatter("--write", good, bad)
            self.assertEqual(result.returncode, 2)
            self.assertIn("duplicate JSON key", result.stderr)
            self.assertEqual(good.read_bytes(), original)

    @unittest.skipUnless(shutil.which("xcrun"), "Xcode writer comparison requires macOS with Xcode")
    def test_matches_xcode_after_a_real_catalog_update(self):
        # An unchanged sync may skip writing. Add a temporary key to force Xcode
        # to serialize each complete catalog, without marking existing keys stale.
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for source in FORMAT.tracked_catalogs():
                with self.subTest(catalog=source):
                    original = json.loads(source.read_bytes())
                    key = "ZZ_STRING_CATALOG_FORMAT_TEST"
                    self.assertNotIn(key, original["strings"])
                    path = folder / source.name
                    path.write_bytes(FORMAT.format_catalog(source.read_bytes()))
                    extraction = folder / "Fixture.stringsdata"
                    extraction.write_text(json.dumps({
                        "source": "Fixture.swift", "version": 1,
                        "tables": {source.stem: [{
                            "key": key, "comment": "",
                            "location": {"startingColumn": 1, "startingLine": 1},
                        }]},
                    }))
                    subprocess.run([
                        "xcrun", "xcstringstool", "sync", str(path),
                        "--stringsdata", str(extraction), "--skip-marking-strings-stale",
                    ], check=True, capture_output=True)
                    written = path.read_bytes()
                    expected = {**original, "strings": {**original["strings"], key: {}}}
                    self.assertEqual(json.loads(written), expected)
                    self.assertEqual(written, FORMAT.format_catalog(written))


if __name__ == "__main__":
    unittest.main()
