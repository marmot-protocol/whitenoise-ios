"""Shared loader for the audit script tests (hyphenated script names)."""
import importlib.util
import pathlib
import sys

AUDIT_DIR = pathlib.Path(__file__).resolve().parents[1] / "audit"
if str(AUDIT_DIR) not in sys.path:
    sys.path.insert(0, str(AUDIT_DIR))


def load(script_name):
    spec = importlib.util.spec_from_file_location(script_name.replace("-", "_"), AUDIT_DIR / (script_name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_tree(root, files):
    root = pathlib.Path(root)
    for relative, content in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    return root
