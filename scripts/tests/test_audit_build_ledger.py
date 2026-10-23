import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name):
    path = ROOT / "scripts" / "audit" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ledger = load("build-ledger.py")


def row(**overrides):
    base = {"suite": "S", "tests": "4", "testClient_sites": "0", "start_sites": "0", "app_state_test_sites": "0",
            "ui_hosting": "0", "image_renderer": "0", "layout_if_needed": "0", "sleep_sites": "0", "poll_loops": "0",
            "run_loop": "0", "subject": "app", "literal_assertion_flags": ""}
    base.update(overrides)
    return base


def cov(unique, jaccard=0.0, partner="T"):
    return {"S": {"unique_lines": str(unique), "max_jaccard": f"{jaccard:.3f}",
                  "overlaps_with": f"{partner}:{jaccard:.2f}" if jaccard else ""}}


def serial(seconds):
    return {"S": {"wall_s": str(seconds)}}


def score(inv, serial_=None, cov_=None, mut=None, hist=None, flagged=0):
    return ledger.score(inv, serial_ or {}, cov_ or {}, mut or {}, hist or {}, flagged)


class ScoreTests(unittest.TestCase):
    def test_mutation_kill_forces_keep_even_with_literal_pins(self):
        value, _, _, _, decision, _, _ = score(row(), serial(0.01), cov(0, 0.95), {"S": 1}, flagged=4)
        self.assertEqual((value, decision), (3, "keep"))

    def test_non_app_subject_is_review_not_delete(self):
        *_, decision, _, _ = score(row(subject="mdk", start_sites="1"))
        self.assertEqual(decision, "review")
        *_, decision_killed, _, _ = score(row(subject="mdk", start_sites="1"), mut={"S": 2})
        self.assertEqual(decision_killed, "re-tier")

    def test_literal_pin_dominated_suite_is_trim_by_distinct_flagged_tests(self):
        *_, decision, _, _ = score(row(tests="4"), cov_=cov(12), flagged=4)
        self.assertEqual(decision, "trim")
        *_, decision_partial, _, _ = score(row(tests="4"), serial(0.05), cov(12), flagged=2)
        self.assertEqual(decision_partial, "keep")

    def test_zero_unique_lines_merges_only_into_a_clear_survivor(self):
        *_, decision, why, target = score(row(), serial(0.02), cov(0, 0.70, "SurvivorTests"))
        self.assertEqual((decision, target), ("merge", "SurvivorTests"))
        *_, decision_dup, _, _ = score(row(), serial(2.5), cov(0, 0.95))
        self.assertEqual(decision_dup, "delete")
        *_, decision_loose, _, _ = score(row(), serial(0.01), cov(0, 0.20))
        self.assertEqual(decision_loose, "keep")

    def test_jaccard_without_zero_unique_is_review_not_merge(self):
        _, _, _, redundancy, decision, _, _ = score(row(), serial(0.05), cov(40, 0.70))
        self.assertEqual((redundancy, decision), (1, "review"))

    def test_appstate_without_client_is_not_a_runtime(self):
        self.assertEqual(ledger.runtime_kind(row(app_state_test_sites="3")), "none")
        self.assertEqual(ledger.runtime_kind(row(testClient_sites="1")), "construct")
        self.assertEqual(ledger.runtime_kind(row(testClient_sites="1", start_sites="1")), "start")

    def test_open_only_runtime_is_purify(self):
        value, cost, *_, decision, _, _ = score(row(testClient_sites="3"), serial(0.3), cov(40))
        self.assertEqual((value, cost, decision), (2, 2, "purify"))

    def test_started_runtime_with_value_is_retier(self):
        *_, decision, _, _ = score(row(start_sites="2", testClient_sites="2"), serial(30), cov(120))
        self.assertEqual(decision, "re-tier")

    def test_fragility_distinguishes_master_and_crashes_from_a_single_pr_failure(self):
        one_pr = {"S": {"failures": "1", "master_failures": "0", "branches": "1", "kinds": "failed"}}
        _, _, fragility, *_ = score(row(), serial(0.2), cov(40), hist=one_pr)
        self.assertEqual(fragility, 2)
        crash = {"S": {"failures": "1", "master_failures": "0", "branches": "1", "kinds": "crashed"}}
        _, _, fragility_crash, *_ = score(row(), serial(0.2), cov(40), hist=crash)
        self.assertEqual(fragility_crash, 3)
        master = {"S": {"failures": "2", "master_failures": "1", "branches": "2", "kinds": "failed"}}
        _, _, fragility_master, _, decision, *_ = score(row(), serial(0.2), cov(40), hist=master)
        self.assertEqual((fragility_master, decision), (3, "purify"))


class SurvivorResolutionTests(unittest.TestCase):
    def make(self, suite, decision, into="", unique=0, tests=1):
        return {"suite": suite, "decision": decision, "merge_into": into, "rationale": "r", "auto_rationale": "a",
                "tests": str(tests)}

    def test_mutual_pair_keeps_the_richer_suite(self):
        rows = [self.make("A", "merge", "B"), self.make("B", "merge", "A")]
        cov_ = {"A": {"unique_lines": "5"}, "B": {"unique_lines": "40"}}
        ledger.resolve_survivors(rows, cov_, {"A", "B"})
        self.assertEqual([(r["suite"], r["decision"], r["merge_into"]) for r in rows],
                         [("A", "merge", "B"), ("B", "keep", "")])

    def test_chain_follows_to_terminal_survivor(self):
        rows = [self.make("A", "merge", "B"), self.make("B", "merge", "C"), self.make("C", "keep")]
        ledger.resolve_survivors(rows, {}, {"A", "B", "C"})
        self.assertEqual(rows[0]["merge_into"], "C")

    def test_survivor_that_is_deleted_turns_into_review(self):
        rows = [self.make("A", "merge", "B"), self.make("B", "delete")]
        ledger.resolve_survivors(rows, {}, {"A", "B"})
        self.assertEqual(rows[0]["decision"], "review")

    def test_unknown_survivor_turns_into_review(self):
        rows = [self.make("A", "merge", "NotASuite")]
        ledger.resolve_survivors(rows, {}, {"A"})
        self.assertEqual((rows[0]["decision"], rows[0]["merge_into"]), ("review", ""))


if __name__ == "__main__":
    unittest.main()
