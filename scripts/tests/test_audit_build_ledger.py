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


class ScoreTests(unittest.TestCase):
    def test_mutation_kill_forces_keep_even_with_literal_pins(self):
        value, cost, _, _, decision, _ = ledger.score(
            row(literal_assertion_flags="constant-literal:4"), {}, cov(0, 0.95), {"S": 1}, {})
        self.assertEqual((value, decision), (3, "keep"))

    def test_mdk_subject_is_delete_only_without_kill(self):
        inv = row(subject="mdk", start_sites="1")
        *_, decision, _ = ledger.score(inv, {}, {}, {}, {})
        self.assertEqual(decision, "delete")
        *_, decision_killed, _ = ledger.score(inv, {}, {}, {"S": 2}, {})
        self.assertEqual(decision_killed, "re-tier")

    def test_literal_pin_dominated_suite_is_trim_not_delete(self):
        *_, decision, _ = ledger.score(row(literal_assertion_flags="constant-literal:5"), {}, cov(12), {}, {})
        self.assertEqual(decision, "trim")

    def test_zero_unique_lines_merges_into_survivor_unless_near_duplicate_and_costly(self):
        inv = row()
        *_, decision, why = ledger.score(inv, {}, cov(0, 0.70, "SurvivorTests"), {}, {}, {"S": {"wall_s": "0.02"}})
        self.assertEqual(decision, "merge")
        self.assertIn("SurvivorTests", why)
        *_, decision_dup, _ = ledger.score(inv, {}, cov(0, 0.95), {}, {}, {"S": {"wall_s": "2.5"}})
        self.assertEqual(decision_dup, "delete")
        *_, decision_cheap_dup, _ = ledger.score(inv, {}, cov(0, 0.95), {}, {}, {"S": {"wall_s": "0.01"}})
        self.assertEqual(decision_cheap_dup, "merge")

    def test_small_overlap_is_not_redundancy(self):
        _, _, _, redundancy, decision, _ = ledger.score(row(), {}, cov(40, 0.20), {}, {}, {"S": {"wall_s": "0.05"}})
        self.assertEqual((redundancy, decision), (0, "keep"))

    def test_open_only_runtime_is_purify(self):
        value, cost, *_, decision, _ = ledger.score(row(testClient_sites="3"), {}, cov(40), {}, {}, {"S": {"wall_s": "0.3"}})
        self.assertEqual((value, cost, decision), (2, 2, "purify"))

    def test_started_runtime_with_value_is_retier(self):
        *_, decision, _ = ledger.score(row(start_sites="2", testClient_sites="2"), {}, cov(120), {}, {}, {"S": {"wall_s": "30"}})
        self.assertEqual(decision, "re-tier")

    def test_suite_cost_prefers_serial_wall_over_file_net(self):
        _, cost, *_ = ledger.score(row(), {"S": {"net_wall_s": "5"}}, cov(40), {}, {}, {"S": {"wall_s": "0.05"}})
        self.assertEqual(cost, 0)

    def test_ci_failure_history_sets_fragility_three_and_purify(self):
        _, _, fragility, _, decision, _ = ledger.score(row(), {}, cov(40), {}, {"S": 2}, {"S": {"wall_s": "0.2"}})
        self.assertEqual((fragility, decision), (3, "purify"))

    def test_tier_classification(self):
        self.assertEqual(ledger.tier(row(testClient_sites="1")), "runtime")
        self.assertEqual(ledger.tier(row(ui_hosting="2")), "uiHosting")
        self.assertEqual(ledger.tier(row()), "pure")


if __name__ == "__main__":
    unittest.main()
