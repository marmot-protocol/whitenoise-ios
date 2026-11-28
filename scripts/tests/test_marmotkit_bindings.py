import copy
import importlib.util
import pathlib
import unittest


script = pathlib.Path(__file__).resolve().parents[1] / "check-marmotkit-bindings.py"
spec = importlib.util.spec_from_file_location("binding_coherence", script)
coherence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coherence)


class MarmotKitCoherenceTests(unittest.TestCase):
    def setUp(self):
        self.provenance = {
            "mdk-sha": "a" * 40, "mdk-tag": "marmotkit-snapshot-" + "a" * 40,
            "channel": "snapshot",
            "published-at": "2026-09-08T00:00:00Z", "uniffi-version": "0.29.4",
            "features": "otlp-export,product-analytics-export", "swiftpm-checksum": "b" * 64,
        }
        self.compiled = {key: self.provenance[key] for key in coherence.VERSION_FIELDS}
        self.target = {
            "name": "MarmotKitFFI", "type": "binary", "checksum": "b" * 64,
            "url": "https://github.com/marmot-protocol/mdk/releases/download/"
                   + self.provenance["mdk-tag"] + "/MarmotKitFFI-snapshot-" + "a" * 40 + ".xcframework.zip",
        }

    def check(self, provenance=None, target=None, compiled=None):
        coherence.check_coherence(provenance or self.provenance,
                                  {"targets": [target or self.target]}, compiled or self.compiled)

    def test_matching_snapshot_rc_nightly_and_formal_release(self):
        self.check()
        for tag, release, channel in (
            ("marmotkit-v0.19.0", "0.19.0", "stable"),
            ("marmotkit-v0.20.0-rc.2", "0.20.0-rc.2", "rc"),
            ("marmotkit-v0.20.0-nightly.20261126", "0.20.0-nightly.20261126", "nightly"),
        ):
            with self.subTest(tag=tag, channel=channel):
                provenance = {**self.provenance, "mdk-tag": tag, "channel": channel}
                compiled = {**self.compiled, "mdk-tag": tag, "channel": channel}
                target = {
                    **self.target,
                    "url": f"https://github.com/marmot-protocol/mdk/releases/download/{tag}/MarmotKitFFI-{release}.xcframework.zip",
                }
                self.check(provenance=provenance, target=target, compiled=compiled)

    def test_channel_disagreeing_with_tag_fails(self):
        for tag, release, wrong_channel in (
            ("marmotkit-v0.20.0-rc.2", "0.20.0-rc.2", "stable"),
            ("marmotkit-v0.19.0", "0.19.0", "rc"),
            ("marmotkit-snapshot-" + "a" * 40, "snapshot-" + "a" * 40, "stable"),
        ):
            with self.subTest(tag=tag, wrong_channel=wrong_channel), self.assertRaises(ValueError):
                provenance = {**self.provenance, "mdk-tag": tag, "channel": wrong_channel}
                compiled = {**self.compiled, "mdk-tag": tag, "channel": wrong_channel}
                target = {
                    **self.target,
                    "url": f"https://github.com/marmot-protocol/mdk/releases/download/{tag}/MarmotKitFFI-{release}.xcframework.zip",
                }
                self.check(provenance=provenance, target=target, compiled=compiled)

    def test_each_compiled_metadata_mismatch_fails(self):
        for field in coherence.VERSION_FIELDS:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(compiled={**self.compiled, field: "different"})

    def test_inconsistent_or_local_binary_target_fails(self):
        for mutation in ({"checksum": "c" * 64}, {"url": "https://example.com/other.zip"},
                         {"path": "Artifacts/MarmotKit.xcframework"}, {"type": "regular"}):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.check(target={**self.target, **mutation})

    def test_snapshot_tag_must_match_source(self):
        changed = copy.copy(self.provenance)
        changed["mdk-tag"] = "marmotkit-snapshot-" + "c" * 40
        with self.assertRaises(ValueError):
            self.check(provenance=changed, compiled={**self.compiled, "mdk-tag": changed["mdk-tag"]})


if __name__ == "__main__":
    unittest.main()
