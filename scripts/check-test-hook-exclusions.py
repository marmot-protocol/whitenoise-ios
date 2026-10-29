#!/usr/bin/env python3
"""Keep SwiftLint's `no_test_hook_in_app_code` exclusions shrinking and honest.

The rule's `excluded` list names app files that still have test-only hooks
(#1241). Each file entry must be one of the files that had hooks when the rule
was added (`BASELINE`), must exist, and must still have a hook in code, so the
list can only shrink and a stale entry can't let a new hook into its file. App
code may not disable the rule for a whole file either.

"In code" uses the rule's own `regex` after removing comments and string
literals, matching its `excluded_match_kinds`. The removal is approximate (a
hook used only inside a string interpolation or a nested block comment can
disagree with SwiftLint), which is enough to spot a file whose hooks are gone.
"""

import argparse
import re
import sys
from pathlib import Path

RULE = "no_test_hook_in_app_code"
APP_DIRS = ("whitenoise-ios", "Shared", "NotificationServiceExtension")
# The match kinds this script removes before looking for a hook.
MATCH_KINDS = {"comment", "doccomment", "string"}
# The tests target, the only directory the rule excludes.
TESTS_ENTRY = "(^|/)whitenoise-iosTests/"
# A file entry, as written in .swiftlint.yml: '(^|/)<escaped relative path>\.swift$'.
FILE_ENTRY = re.compile(r"^\(\^\|/\)(?P<path>.+\\\.swift)\$$")
# The files that had hooks when the rule was added. Entries may only leave the
# exclusions, so every entry must be one of these.
BASELINE = frozenset({
    "Shared/L10n.swift",
    "whitenoise-ios/Chats/ChatsListViewModel.swift",
    "whitenoise-ios/Chats/NewChatFlowViewModel.swift",
    "whitenoise-ios/Conversation/ComposerModel.swift",
    "whitenoise-ios/Conversation/ConversationAgentEventProjectionCache.swift",
    "whitenoise-ios/Conversation/ConversationDaySectionProjectionCache.swift",
    "whitenoise-ios/Conversation/ConversationMarkdownProjectionCache.swift",
    "whitenoise-ios/Conversation/ConversationMediaProjectionCache.swift",
    "whitenoise-ios/Conversation/ConversationViewModel.swift",
    "whitenoise-ios/Conversation/StreamWatcher.swift",
    "whitenoise-ios/Conversation/TimelineStore.swift",
    "whitenoise-ios/Conversation/VoiceMessageRecorder.swift",
    "whitenoise-ios/Core/AppState+Profiles.swift",
    "whitenoise-ios/Core/AppState.swift",
    "whitenoise-ios/Core/GroupAvatarImageLoader.swift",
    "whitenoise-ios/Core/MarkdownTimestampRefresh.swift",
    "whitenoise-ios/Core/NotificationCoordinator.swift",
    "whitenoise-ios/Core/ProfileStore.swift",
    "whitenoise-ios/Core/RelativeTime.swift",
    "whitenoise-ios/Core/RemoteImageLoader.swift",
    "whitenoise-ios/Core/RuntimeLifecycle.swift",
    "whitenoise-ios/Group/GroupDetailsViewModel.swift",
    "whitenoise-ios/Group/GroupMemberOrdering.swift",
    "whitenoise-ios/Recipients/DirectChatStarter.swift",
    "whitenoise-ios/Recipients/RecipientUserSearch.swift",
})
# Comments, then raw and plain string literals (multi-line first), in source order.
NON_CODE = re.compile(
    r'//[^\n]*|/\*.*?\*/'
    r'|(?P<mh>#+)""".*?"""(?P=mh)|(?P<sh>#+)"[^\n]*?"(?P=sh)'
    r'|"""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*"',
    re.DOTALL,
)
# `swiftlint:disable` without `:next`, `:this` or `:previous`, naming the rule.
WHOLE_FILE_DISABLE = re.compile(rf"swiftlint:disable\s[^\n]*\b{RULE}\b")


class ConfigError(Exception):
    pass


def rule_block(config: str) -> list[str]:
    """The rule's lines, up to the next line indented two spaces or less."""
    lines = config.splitlines()
    try:
        start = lines.index(f"  {RULE}:")
    except ValueError:
        raise ConfigError(f".swiftlint.yml has no `{RULE}` custom rule")
    block = []
    for line in lines[start + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith("   "):
            break
        block.append(line)
    return block


def rule_settings(config: str) -> tuple[str, list[str], list[str]]:
    """The rule's regex, `excluded` entries and `excluded_match_kinds`."""
    regex = None
    lists: dict[str, list[str]] = {}
    current = None
    for line in rule_block(config):
        key = re.match(r"^    (\w+):(.*)$", line)
        if key:
            name, value = key.group(1), key.group(2).strip()
            current = None
            if name == "regex":
                quoted = re.fullmatch(r"'((?:[^']|'')*)'", value)
                if not quoted:
                    raise ConfigError(f"write `{RULE}`'s regex single-quoted")
                regex = quoted.group(1).replace("''", "'")
            elif name in ("excluded", "excluded_match_kinds"):
                if value:
                    raise ConfigError(f"write `{RULE}`'s {name} as a list, one '- ...' item per line")
                current = lists.setdefault(name, [])
            continue
        if current is None:
            continue
        item = re.match(r"^    - (?:'(.*)'|(\w+))$", line)
        if not item:
            raise ConfigError(f"unexpected line in `{RULE}`'s lists: {line.strip()}")
        current.append(item.group(1) if item.group(1) is not None else item.group(2))
    if regex is None:
        raise ConfigError(f"`{RULE}` has no regex")
    if not lists.get("excluded"):
        raise ConfigError(f"`{RULE}` has no `excluded` list")
    return regex, lists["excluded"], lists.get("excluded_match_kinds", [])


def has_hook_in_code(hook: re.Pattern, source: str) -> bool:
    return hook.search(NON_CODE.sub("", source)) is not None


def problems(root: Path) -> list[str]:
    regex, entries, kinds = rule_settings((root / ".swiftlint.yml").read_text(encoding="utf-8"))
    hook = re.compile(regex)
    found = []
    if set(kinds) != MATCH_KINDS:
        found.append(f"`{RULE}`'s excluded_match_kinds must be {sorted(MATCH_KINDS)}, which this script mirrors")
    for entry in entries:
        if entry == TESTS_ENTRY:
            continue
        match = FILE_ENTRY.match(entry)
        if not match:
            found.append(f"{entry}: write file exclusions as '(^|/)<path>\\.swift$'")
            continue
        relative = re.sub(r"\\(.)", r"\1", match.group("path"))
        path = root / relative
        if relative not in BASELINE:
            found.append(f"{relative}: the exclusions only shrink; inject the dependency instead of adding a hook")
        elif not path.is_file():
            found.append(f"{relative}: excluded but missing")
        elif not has_hook_in_code(hook, path.read_text(encoding="utf-8")):
            found.append(f"{relative}: excluded but has no hook left; remove it from `{RULE}`'s exclusions")
    for directory in APP_DIRS:
        for path in sorted((root / directory).rglob("*.swift")):
            if WHOLE_FILE_DISABLE.search(path.read_text(encoding="utf-8")):
                found.append(f"{path.relative_to(root)}: disable `{RULE}` per line with `swiftlint:disable:next`")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    try:
        found = problems(parser.parse_args().root)
    except ConfigError as error:
        found = [str(error)]
    for problem in found:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
