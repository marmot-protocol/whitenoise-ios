# justfile — whitenoise-ios

# Default recipe: show all available commands.
default:
    @just --list

# Pin develop to the latest verified MarmotKit Release Candidate.
sync-rc *args:
    @./scripts/sync-rc.sh {{args}}

# Swap the pinned RC for the Stable MarmotKit release MDK promoted from it.
promote-stable *args:
    @./scripts/promote-stable.sh {{args}}

# Install a published formal release or immutable master snapshot.
sync-bindings release:
    @./scripts/sync-bindings.sh {{release}}

# Check MarmotKit provenance and branch release-channel policy.
check-marmotkit:
    @python3 scripts/check-marmotkit-bindings.py
    @./scripts/ci/check-marmotkit-channel.sh

# Lint Swift files and localization catalogs
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

# Full pre-commit gate. Runs the exact same checks CI runs.
precommit:
    @./scripts/lint.sh
    @python3 scripts/check-marmotkit-bindings.py
    @./scripts/ci/check-marmotkit-channel.sh
    @./scripts/test.sh
    @echo "✓ precommit passed"
