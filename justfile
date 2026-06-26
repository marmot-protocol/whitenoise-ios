# justfile — whitenoise-ios

# Default recipe: show all available commands.
default:
    @just --list

# The xcframework is git-ignored; this rebuilds it locally from the sibling
# ../darkmatter Rust repo (needs the toolchain) and stamps provenance. Run on a
# fresh clone and after Rust changes.
sync-bindings:
    @./scripts/sync-bindings.sh

# Lint Swift files
lint:
    @./scripts/lint.sh

# Auto-corrects everything SwiftLint can auto-correct
autofix:
    @swiftlint lint --fix --config .swiftlint.yml || true
    @./scripts/lint.sh

test:
    @./scripts/test.sh

# Full pre-commit gate. Runs the exact same command CI runs.
precommit:
    @./scripts/lint.sh
    @./scripts/test.sh
    @echo "✓ precommit (lint only)"
