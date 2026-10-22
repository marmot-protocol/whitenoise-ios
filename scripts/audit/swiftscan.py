"""Small Swift source scanner shared by the test-audit tooling.

This is tooling that reads test sources to inventory them; it is not a test.
It masks comments and string literals, matches braces, and enumerates
top-level declarations, test suites and the test functions inside them.
Standard library only.
"""
import bisect
import dataclasses
import pathlib
import re

IDENTIFIER = r"[A-Za-z_][A-Za-z0-9_]*"
TYPE_KEYWORDS = ("struct", "class", "enum", "actor", "extension", "protocol")
DECL_KEYWORDS = TYPE_KEYWORDS + ("func", "let", "var", "typealias")
# `class func` / `class var` are modifiers, not type declarations.
DECL_RE = re.compile(r"(?<![\w.])(%s)\s+(?!(?:func|var|let|static|final)\b)(`?%s`?)"
                     % ("|".join(DECL_KEYWORDS), IDENTIFIER))
MODIFIERS = {
    "private", "fileprivate", "internal", "public", "open", "package", "final", "static",
    "class", "override", "nonisolated", "mutating", "nonmutating", "indirect", "lazy",
    "weak", "unowned", "required", "convenience", "dynamic", "optional", "async", "throws",
}


@dataclasses.dataclass
class Masked:
    """Three views of one source file, all the same length.

    ``source`` is the raw text, ``text`` has comments blanked, ``code`` has
    comments and string-literal contents blanked (quotes and interpolated
    code are kept). Newlines are preserved so offsets and lines line up.
    """
    source: str
    text: str
    code: str
    _line_starts: list = dataclasses.field(default_factory=list, repr=False)
    _depths: list = dataclasses.field(default_factory=list, repr=False)

    @property
    def depths(self):
        if not self._depths:
            self._depths = brace_depths(self.code)
        return self._depths

    def line(self, offset):
        if not self._line_starts:
            self._line_starts = [0] + [m.end() for m in re.finditer(r"\n", self.source)]
        return bisect.bisect_right(self._line_starts, offset)


class _Masker:
    def __init__(self, source):
        self.src = source
        self.n = len(source)
        self.text = list(source)
        self.code = list(source)

    def blank(self, start, end, comment):
        for k in range(start, end):
            if self.src[k] != "\n":
                self.code[k] = " "
                if comment:
                    self.text[k] = " "

    def run(self):
        self.scan_code(0, None)
        return Masked(self.src, "".join(self.text), "".join(self.code))

    def scan_code(self, i, closer):
        src, n = self.src, self.n
        depth = 0
        while i < n:
            c = src[i]
            if c == "/" and src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                self.blank(i, j, True)
                i = j
            elif c == "/" and src.startswith("/*", i):
                j = self.block_comment_end(i)
                self.blank(i, j, True)
                i = j
            elif c == '"' or (c == "#" and re.match(r'#+"', src[i:i + 16])):
                i = self.scan_string(i)
            elif closer is not None and c == "(":
                depth += 1
                i += 1
            elif closer is not None and c == ")":
                if depth == 0:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return i

    def block_comment_end(self, i):
        src, n = self.src, self.n
        depth = 0
        while i < n:
            if src.startswith("/*", i):
                depth += 1
                i += 2
            elif src.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    def scan_string(self, i):
        src, n = self.src, self.n
        match = re.match(r'(#*)("""|")', src[i:i + 16])
        hashes, delim = match.group(1), match.group(2)
        i += len(match.group(0))
        end_token = delim + hashes
        escape = "\\" + hashes
        content_start = i
        while i < n:
            if src.startswith(escape + "(", i):
                self.blank(content_start, i, False)
                i = self.scan_code(i + len(escape) + 1, ")")
                content_start = i
            elif src.startswith(escape, i):
                i += len(escape) + 1
            elif src.startswith(end_token, i):
                self.blank(content_start, i, False)
                return i + len(end_token)
            elif delim == '"' and src[i] == "\n":
                self.blank(content_start, i, False)
                return i
            else:
                i += 1
        self.blank(content_start, n, False)
        return n


def mask(source):
    return _Masker(source).run()


def match_close(code, open_index):
    """Return the index of the bracket closing the one at ``open_index``."""
    opener = code[open_index]
    closer = {"(": ")", "[": "]", "{": "}"}[opener]
    depth = 0
    for k in range(open_index, len(code)):
        c = code[k]
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return k
    return len(code)


def brace_depths(code):
    """Return a list giving the brace depth before each character."""
    depths = [0] * (len(code) + 1)
    depth = 0
    for k, c in enumerate(code):
        depths[k] = depth
        if c == "{":
            depth += 1
        elif c == "}":
            depth = max(0, depth - 1)
    depths[len(code)] = depth
    return depths


@dataclasses.dataclass
class Attribute:
    name: str
    arguments: str  # text inside the parentheses, or ""


@dataclasses.dataclass
class Declaration:
    keyword: str
    name: str
    start: int  # offset of the keyword
    name_end: int
    header: str  # attributes and modifiers preceding the keyword (code view)
    inheritance: str
    body_start: int  # offset of "{" or -1
    body_end: int  # offset of "}" or end of statement
    depth: int
    attributes: list
    modifiers: set

    def has_attribute(self, name):
        return any(a.name == name for a in self.attributes)

    def attribute(self, name):
        for a in self.attributes:
            if a.name == name:
                return a
        return None


def parse_header(header):
    attributes, modifiers = [], set()
    i = 0
    while i < len(header):
        match = re.compile(r"@(%s)" % IDENTIFIER).match(header, i)
        if match:
            name, j = match.group(1), match.end()
            arguments = ""
            k = j
            while k < len(header) and header[k] in " \t":
                k += 1
            if k < len(header) and header[k] == "(":
                close = match_close(header, k)
                arguments = header[k + 1:close]
                j = close + 1
            attributes.append(Attribute(name, arguments))
            i = j
            continue
        word = re.compile(IDENTIFIER).match(header, i)
        if word:
            if word.group(0) in MODIFIERS:
                modifiers.add(word.group(0))
            i = word.end()
            continue
        i += 1
    return attributes, modifiers


def _statement_end(code, start):
    """Best-effort end of a brace-less declaration: the end of its last line
    once brackets opened on the way are balanced."""
    k = start
    n = len(code)
    depth = 0
    while k < n:
        c = code[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                return k
        elif c == "\n" and depth <= 0:
            return k
        k += 1
    return n


def declarations(masked, start=0, end=None, depth=0):
    """Yield declarations whose keyword sits at ``depth`` inside [start, end)."""
    code = masked.code
    end = len(code) if end is None else end
    depths = masked.depths
    previous_end = start
    for match in DECL_RE.finditer(code, start, end):
        at = match.start()
        if depths[at] != depth or at < previous_end:
            continue
        keyword, name = match.group(1), match.group(2).strip("`")
        header = _header_before(code, previous_end, at)
        name_end = match.end()
        k = name_end
        if code[k:k + 1] == "<":
            k = match_close_angle(code, k) + 1
        inheritance = ""
        body_start, body_end = -1, -1
        if keyword in TYPE_KEYWORDS:
            brace = code.find("{", k, end)
            if brace < 0:
                body_end = _statement_end(code, k)
            else:
                inheritance = code[k:brace].strip().lstrip(":").strip()
                body_start = brace
                body_end = match_close(code, brace)
        elif keyword == "func":
            paren = code.find("(", k, end)
            if paren < 0:
                body_end = _statement_end(code, k)
            else:
                close = match_close(code, paren)
                brace = code.find("{", close, end)
                line_end = code.find("\n", close)
                # Only accept a body brace before the next declaration keyword.
                next_decl = DECL_RE.search(code, close, end)
                limit = next_decl.start() if next_decl else end
                if brace < 0 or brace > limit:
                    body_end = line_end if line_end >= 0 else end
                else:
                    body_start = brace
                    body_end = match_close(code, brace)
        else:
            body_end = _statement_end(code, k)
            if keyword == "var":
                # Computed property or property with observers.
                eq = code.find("=", k, body_end)
                brace = code.find("{", k, body_end + 1)
                if brace >= 0 and (eq < 0 or brace < eq):
                    body_start = brace
                    body_end = match_close(code, brace)
        attributes, modifiers = parse_header(header)
        decl = Declaration(keyword, name, at, name_end, header, inheritance, body_start,
                           body_end, depth, attributes, modifiers)
        previous_end = body_end + 1
        yield decl


def match_close_angle(code, open_index):
    depth = 0
    for k in range(open_index, len(code)):
        if code[k] == "<":
            depth += 1
        elif code[k] == ">":
            depth -= 1
            if depth == 0:
                return k
    return open_index


def _header_before(code, start, at):
    """Attributes and modifiers immediately preceding ``at``.

    Takes the last non-blank paragraph before ``at`` and keeps only its
    trailing run of ``@attribute(...)`` tokens and modifier words, so a
    preceding statement or ``import`` line never leaks into the header.
    """
    segment = code[start:at]
    paragraph_start = 0
    for match in re.finditer(r"\n[ \t]*\n", segment):
        if segment[match.end():].strip():
            paragraph_start = match.end()
    paragraph = segment[paragraph_start:]
    i = 0
    header_start = 0
    attribute = re.compile(r"@(%s)" % IDENTIFIER)
    word = re.compile(IDENTIFIER)
    while i < len(paragraph):
        c = paragraph[i]
        if c.isspace():
            i += 1
            continue
        if c == "#" and re.match(r"#(if|elseif|else|endif)\b", paragraph[i:i + 8]):
            newline = paragraph.find("\n", i)
            i = len(paragraph) if newline < 0 else newline + 1
            continue
        match = attribute.match(paragraph, i)
        if match:
            j = match.end()
            k = j
            while k < len(paragraph) and paragraph[k] in " \t":
                k += 1
            if k < len(paragraph) and paragraph[k] == "(":
                j = match_close(paragraph, k) + 1
            i = j
            continue
        match = word.match(paragraph, i)
        if match and match.group(0) in MODIFIERS:
            i = match.end()
            continue
        if match:
            i = match.end()
        elif c in "([{":
            i = match_close(paragraph, i) + 1
        else:
            i += 1
        header_start = i
    return paragraph[header_start:].strip()


@dataclasses.dataclass
class TestFunction:
    name: str
    signature: str
    start: int
    body_start: int
    body_end: int
    declaration: Declaration
    path: str = ""
    nesting: str = ""  # "Inner" for a test inside a nested type

    @property
    def qualified_name(self):
        return self.signature if not self.nesting else "%s/%s" % (self.nesting, self.signature)


@dataclasses.dataclass
class SuitePart:
    """One brace range contributing to a suite: its declaration or an extension."""
    path: str
    masked: Masked
    declaration: Declaration

    @property
    def start(self):
        return self.declaration.body_start

    @property
    def end(self):
        return self.declaration.body_end


@dataclasses.dataclass
class Suite:
    name: str
    keyword: str
    framework: str
    declaration: Declaration
    tests: list
    path: str
    line: int
    parts: list = dataclasses.field(default_factory=list)


def signature_of(masked, decl):
    code = masked.code
    k = decl.name_end
    if code[k:k + 1] == "<":
        k = match_close_angle(code, k) + 1
    paren = code.find("(", k)
    if paren < 0:
        return decl.name + "()"
    close = match_close(code, paren)
    params = code[paren + 1:close]
    labels = []
    for param in _split_top_level(params, ","):
        param = param.strip()
        if not param:
            continue
        before_colon = _split_top_level(param, ":")[0].strip()
        words = [w.strip("`") for w in before_colon.split() if not w.startswith("@") and w not in ("inout", "borrowing", "consuming")]
        if not words:
            continue
        labels.append(words[0])
    return "%s(%s)" % (decl.name, "".join(label + ":" for label in labels))


def _split_top_level(text, separator):
    parts, depth, current = [], 0, []
    for c in text:
        if c in "([{<":
            depth += 1
        elif c in ")]}>":
            depth -= 1
        if c == separator and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(c)
    parts.append("".join(current))
    return parts


def is_suite(decl):
    if decl.keyword not in ("struct", "class", "enum", "actor"):
        return False
    if decl.has_attribute("Suite"):
        return True
    if "XCTestCase" in decl.inheritance.split(",")[0]:
        return True
    return decl.name.endswith("Tests")


def framework_of(decl):
    return "XCTest" if "XCTestCase" in decl.inheritance else "SwiftTesting"


def tests_in(masked, decl, framework, path="", nesting=""):
    """Test functions inside a suite body, recursing into nested types."""
    if decl.body_start < 0:
        return []
    found = []
    for member in declarations(masked, decl.body_start + 1, decl.body_end, decl.depth + 1):
        if member.keyword == "func" and member.body_start >= 0:
            if framework == "XCTest":
                if not member.name.startswith("test") or "static" in member.modifiers or "class" in member.modifiers:
                    continue
            elif not member.has_attribute("Test"):
                continue
            found.append(TestFunction(member.name, signature_of(masked, member), member.start,
                                      member.body_start, member.body_end, member, path, nesting))
        elif member.keyword in ("struct", "class", "enum", "actor") and member.body_start >= 0:
            inner = nesting + "/" + member.name if nesting else member.name
            found.extend(tests_in(masked, member, framework, path, inner))
    return found


def suites_in_file(path, masked=None):
    """Suites declared in one file (extensions are attached by ``collect_suites``)."""
    path = pathlib.Path(path)
    masked = masked or mask(path.read_text(encoding="utf-8"))
    suites = []
    for decl in declarations(masked):
        if not is_suite(decl):
            continue
        framework = framework_of(decl)
        suite = Suite(decl.name, decl.keyword, framework, decl,
                      tests_in(masked, decl, framework, str(path)), str(path),
                      masked.line(decl.start))
        suite.parts.append(SuitePart(str(path), masked, decl))
        suites.append(suite)
    return suites


def extensions_in_file(path, masked):
    return [(decl, SuitePart(str(path), masked, decl))
            for decl in declarations(masked) if decl.keyword == "extension" and decl.body_start >= 0]


def collect_suites(directory, warn=None):
    """All suites under ``directory`` with their extension blocks merged in.

    Suites are keyed by name so the tooling works whether a suite and its
    extensions share a file or are split across files. Duplicate suite
    names are reported through ``warn`` and kept as separate rows.
    """
    suites, extensions, masks = [], [], {}
    for path in swift_files(directory):
        masked = mask(path.read_text(encoding="utf-8"))
        masks[str(path)] = masked
        suites.extend(suites_in_file(path, masked))
        extensions.extend(extensions_in_file(path, masked))
    by_name = {}
    for suite in suites:
        if suite.name in by_name and warn:
            warn("duplicate suite name %s in %s and %s" % (suite.name, by_name[suite.name].path, suite.path))
        by_name.setdefault(suite.name, suite)
    for decl, part in extensions:
        suite = by_name.get(decl.name)
        if suite is None:
            continue
        suite.parts.append(part)
        suite.tests.extend(tests_in(part.masked, decl, suite.framework, part.path))
    suites.sort(key=lambda s: (s.name, s.path))
    return suites, masks


def swift_files(directory):
    return sorted(p for p in pathlib.Path(directory).rglob("*.swift") if p.is_file())


def count_pattern(pattern, text, start, end):
    return sum(1 for _ in re.compile(pattern).finditer(text, start, end))


def identifiers(code, start=0, end=None):
    end = len(code) if end is None else end
    return [m.group(0) for m in re.finditer(IDENTIFIER, code[start:end])]


def all_type_names(masked, start=0, end=None, depth=0, names=None):
    """Names of type declarations at any depth (recursing through bodies)."""
    names = set() if names is None else names
    for decl in declarations(masked, start, end, depth):
        if decl.keyword in TYPE_KEYWORDS and decl.keyword != "extension":
            names.add(decl.name)
        if decl.body_start >= 0 and decl.keyword in TYPE_KEYWORDS:
            all_type_names(masked, decl.body_start + 1, decl.body_end, depth + 1, names)
    return names
