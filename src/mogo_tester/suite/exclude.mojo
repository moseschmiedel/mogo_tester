"""Excluding discovered test files by glob pattern."""

from std.pathlib import Path

from ..fs.paths import clean


comptime _STAR = UInt8(ord("*"))
comptime _QUESTION = UInt8(ord("?"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))
comptime _BANG = UInt8(ord("!"))
comptime _CARET = UInt8(ord("^"))
comptime _DASH = UInt8(ord("-"))
comptime _BACKSLASH = UInt8(ord("\\"))


struct Exclusion(Movable):
    """Discovered files split into those to run and those excluded, plus the
    patterns that matched no file."""

    var kept: List[Path]
    var skipped: List[Path]
    var unmatched: List[String]

    def __init__(out self):
        self.kept = List[Path]()
        self.skipped = List[Path]()
        self.unmatched = List[String]()


def apply_excludes(
    paths: List[Path], patterns: List[String], out result: Exclusion
):
    """Splits paths by whether any pattern matches them.

    A pattern matches a path if it matches the lexically cleaned path or its
    basename; see `glob_match`. Order is preserved in both lists.
    """
    result = Exclusion()
    var used = List[Bool](length=len(patterns), fill=False)
    for path in paths:
        var excluded = False
        for i in range(len(patterns)):
            if exclude_matches(patterns[i], path):
                used[i] = True
                excluded = True
        if excluded:
            result.skipped.append(path)
        else:
            result.kept.append(path)
    for i in range(len(patterns)):
        if not used[i]:
            result.unmatched.append(patterns[i])


def exclude_matches(pattern: String, path: Path) -> Bool:
    """Reports whether pattern matches the cleaned path or its basename."""
    var cleaned = clean(path)
    var normalized = clean(Path(pattern)).path
    return glob_match(normalized, cleaned.path) or glob_match(
        normalized, cleaned.name()
    )


def glob_match(pattern: String, path: String) -> Bool:
    """Reports whether a slash-separated glob pattern matches path.

    Within a path element, `*` matches any run of bytes, `?` matches one
    byte, `[...]` matches a byte class (ranges like `a-z`, negation with `!`
    or `^`), and `\\` escapes the next byte. A `**` element matches zero or
    more whole path elements. An unterminated `[` matches itself.
    """
    return _match_parts(_split(pattern), 0, _split(path), 0)


def _split(text: String, out parts: List[List[UInt8]]):
    parts = List[List[UInt8]]()
    for part in text.split("/"):
        parts.append(List[UInt8](part.as_bytes()))


def _is_double_star(part: List[UInt8]) -> Bool:
    return len(part) == 2 and part[0] == _STAR and part[1] == _STAR


def _match_parts(
    pattern: List[List[UInt8]],
    pattern_index: Int,
    path: List[List[UInt8]],
    path_index: Int,
) -> Bool:
    var pi = pattern_index
    var si = path_index
    while pi < len(pattern):
        if _is_double_star(pattern[pi]):
            # Collapse consecutive `**` elements.
            while pi + 1 < len(pattern) and _is_double_star(pattern[pi + 1]):
                pi += 1
            if pi + 1 == len(pattern):
                return True
            for start in range(si, len(path) + 1):
                if _match_parts(pattern, pi + 1, path, start):
                    return True
            return False
        if si >= len(path) or not _match_element(pattern[pi], path[si]):
            return False
        pi += 1
        si += 1
    return si == len(path)


def _match_element(pattern: List[UInt8], text: List[UInt8]) -> Bool:
    var pi = 0
    var si = 0
    var star = -1
    var mark = 0
    while si < len(text):
        if pi < len(pattern):
            if pattern[pi] == _STAR:
                star = pi
                mark = si
                pi += 1
                continue
            var next = _match_byte(pattern, pi, text[si])
            if next >= 0:
                pi = next
                si += 1
                continue
        if star >= 0:
            # Let the last `*` absorb one more byte and retry.
            pi = star + 1
            mark += 1
            si = mark
            continue
        return False
    while pi < len(pattern) and pattern[pi] == _STAR:
        pi += 1
    return pi == len(pattern)


def _match_byte(pattern: List[UInt8], index: Int, byte: UInt8) -> Int:
    """Matches one pattern token at index against byte; returns the index
    after the token, or -1 if it does not match."""
    var token = pattern[index]
    if token == _QUESTION:
        return index + 1
    if token == _BACKSLASH and index + 1 < len(pattern):
        return index + 2 if pattern[index + 1] == byte else -1
    if token == _LBRACKET:
        var parsed = _match_class(pattern, index, byte)
        if parsed[1] >= 0:
            return parsed[1] if parsed[0] else -1
    return index + 1 if token == byte else -1


def _match_class(
    pattern: List[UInt8], start: Int, byte: UInt8
) -> Tuple[Bool, Int]:
    """Matches the class starting at `pattern[start] == '['`. Returns whether
    byte matched and the index after `]`, or -1 if the class is unterminated.
    """
    var i = start + 1
    var negate = False
    if i < len(pattern) and (pattern[i] == _BANG or pattern[i] == _CARET):
        negate = True
        i += 1
    var matched = False
    var first = True
    while i < len(pattern):
        if pattern[i] == _RBRACKET and not first:
            return (matched != negate, i + 1)
        first = False
        var low = pattern[i]
        if low == _BACKSLASH and i + 1 < len(pattern):
            i += 1
            low = pattern[i]
        i += 1
        var high = low
        if (
            i + 1 < len(pattern)
            and pattern[i] == _DASH
            and pattern[i + 1] != _RBRACKET
        ):
            i += 1
            high = pattern[i]
            if high == _BACKSLASH and i + 1 < len(pattern):
                i += 1
                high = pattern[i]
            i += 1
        if low <= byte and byte <= high:
            matched = True
    return (False, -1)
