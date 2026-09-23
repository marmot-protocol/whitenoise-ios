# justfile — whitenoise-ios

# Default recipe: show all available commands.
default:
    @just --list

# Install a published formal release or immutable master snapshot.
sync-bindings release:
	@./scripts/sync-bindings.sh {{release}}

# Lint Swift files
lint:
    @./scripts/lint.sh

# Auto-corrects everything SwiftLint can auto-correct
autofix:
    @swiftlint lint --fix --config .swiftlint.yml || true
    @./scripts/lint.sh

test:
    @./scripts/test.sh

# Remove local build output: build/ and this project's DerivedData
clean:
    @rm -rf build
    @rm -rf ~/Library/Developer/Xcode/DerivedData/whitenoise-ios-*
    @echo "✓ cleaned build/ and whitenoise-ios DerivedData"

# Full pre-commit gate. Runs the exact same command CI runs.
precommit:
    @./scripts/lint.sh
    @./scripts/test.sh
    @echo "✓ precommit (lint only)"
