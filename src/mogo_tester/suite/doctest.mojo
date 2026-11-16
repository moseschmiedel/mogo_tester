"""Doctest discovery and program generation.

A doctest is a set of fenced Mojo code blocks that share a `doctest` name,
written in Markdown files or in docstrings of `.mojo` files. The fence syntax
follows Modo:

    ```mojo {doctest="name" global=true hide=true}

Blocks marked `global=true` are emitted at file scope, in source order. All
other blocks with the same name form the body of a generated
`def main() raises:`. A doctest whose global blocks define `def main` and that
has no other blocks is emitted unchanged. `hide` only affects rendered docs
and is ignored here.

Blocks are grouped per Markdown file, and per docstring in `.mojo` files, so
two docstrings may reuse the same doctest name.
"""

from std.pathlib import Path

from ..fs.paths import clean

comptime MIN_FENCE = 3
comptime MAIN_DEF = "def main("
comptime BODY_INDENT = "    "


@fieldwise_init
struct Doctest(Copyable, Movable):
    """One generated doctest program.

    `line_map[i]` is the 1-based source line of generated line `i + 1`, or 0
    for lines the generator added. `error` is non-empty when no valid program
    could be generated; `code` is empty in that case.
    """

    var source: String
    var name: String
    var line: Int
    var code: String
    var line_map: List[Int]
    var error: String

    def label(self) -> String:
        """Returns the report label, for example `docs/guide.md:12#intro`."""
        return self.source + ":" + String(self.line) + "#" + self.name


@fieldwise_init
struct FenceInfo(Copyable, Movable):
    var name: String
    var is_global: Bool


@fieldwise_init
struct Block(Copyable, Movable):
    var is_global: Bool
    var lines: List[String]
    var first_line: Int


@fieldwise_init
struct Group(Copyable, Movable):
    var name: String
    var line: Int
    var blocks: List[Block]
    var error: String


def is_doctest_source(path: Path) -> Bool:
    """Reports whether a file may contain doctests."""
    var suffix = path.suffix()
    return suffix == ".mojo" or suffix == ".md"


def discover_doctest_files(paths: List[Path], out files: List[Path]) raises:
    """Returns the sorted doctest source files under `paths`.

    Directories are searched recursively, skipping entries whose name starts
    with `.`. Files given directly are included whatever their extension.

    Raises:
        Error: If an operand does not exist or a directory cannot be listed.
    """
    files = List[Path]()
    for path in paths:
        if not path.exists():
            raise Error(
                "discover doctests in ", path, ": no such file or directory"
            )
        if path.is_dir():
            _walk(clean(path), files)
        else:
            files.append(clean(path))
    sort(Span(files))


def _walk(dir: Path, mut files: List[Path]) raises:
    var entries: List[Path]
    try:
        entries = dir.listdir()
    except e:
        raise Error("discover doctests in ", dir, ": ", e)
    for entry in entries:
        if entry.path.startswith("."):
            continue
        var child = dir / entry.path
        if child.is_dir():
            _walk(child, files)
        elif is_doctest_source(child):
            files.append(child)


def parse_fence_info(info: String) raises -> Optional[FenceInfo]:
    """Parses the text after a ` ```mojo ` fence opener.

    Returns `None` when the fence has no `doctest` attribute. Raises on
    malformed attribute lists.
    """
    var text = String(info.strip())
    if text.byte_length() == 0:
        return None
    if not text.startswith("{") or not text.endswith("}"):
        raise Error("expected `{...}` attributes after ```mojo, got: " + text)

    var name = Optional[String]()
    var is_global = False
    var i = 1
    var end = text.byte_length() - 1
    while i < end:
        if String(text[byte=i]) == " " or String(text[byte=i]) == "\t":
            i += 1
            continue
        var key_start = i
        while i < end and String(text[byte=i]) != "=":
            i += 1
        if i >= end:
            raise Error("attribute without value in: " + text)
        var key = String(text[byte=key_start:i].strip())
        i += 1
        var value: String
        if i < end and String(text[byte=i]) == '"':
            i += 1
            var value_start = i
            while i < end and String(text[byte=i]) != '"':
                i += 1
            if i >= end:
                raise Error("unterminated quoted value in: " + text)
            value = String(text[byte=value_start:i])
            i += 1
        else:
            var value_start = i
            while (
                i < end
                and String(text[byte=i]) != " "
                and String(text[byte=i]) != "\t"
            ):
                i += 1
            value = String(text[byte=value_start:i])

        if key == "doctest":
            name = value
        elif key == "global":
            is_global = _parse_bool(key, value)

    if not name:
        return None
    if name.value().byte_length() == 0:
        raise Error("empty doctest name in: " + text)
    return FenceInfo(name.value(), is_global)


def _parse_bool(key: String, value: String) raises -> Bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise Error(key + " must be true or false, got: " + value)


def scan_doctests(source: String, text: String, out doctests: List[Doctest]):
    """Extracts and generates every doctest in one file's contents.

    `source` is the path used in labels and error messages. Doctests are
    returned in order of their first block.
    """
    var track_docstrings = source.endswith(".mojo")
    var groups = List[Group]()
    var keys = Dict[String, Int]()
    var scope = 0
    var docstring_delimiter = String()
    var lines = text.split("\n")
    var i = 0
    var count = len(lines)
    while i < count:
        var line = String(lines[i])
        var stripped = String(line.lstrip())
        var fence_char = _fence_char(stripped)
        var fence_size = _char_run(stripped, fence_char)
        if fence_size < MIN_FENCE:
            if track_docstrings:
                scope += _docstring_toggles(line, docstring_delimiter)
            i += 1
            continue

        var open_line = i + 1
        var indent = String(
            line[byte = : line.byte_length() - stripped.byte_length()]
        )
        var info = String(stripped[byte=fence_size:])
        var fence: Optional[FenceInfo] = None
        var fence_error = String()
        if (
            info == "mojo"
            or info.startswith("mojo ")
            or info.startswith("mojo{")
        ):
            try:
                fence = parse_fence_info(String(info[byte=4:]))
            except e:
                fence_error = String(e)

        var body = List[String]()
        var closed = False
        i += 1
        while i < count:
            var content = String(lines[i])
            var trimmed = String(content.strip())
            var run = _char_run(trimmed, fence_char)
            if run >= fence_size and run == trimmed.byte_length():
                closed = True
                break
            body.append(_dedent(content, indent))
            i += 1
        i += 1

        if not fence and not fence_error:
            continue
        var name = fence.value().name if fence else String("<invalid>")
        var key = String(scope) + "\x00" + name
        var index: Int
        if key in keys:
            index = keys.get(key, 0)
        else:
            index = len(groups)
            keys[key] = index
            groups.append(Group(name, open_line, List[Block](), String()))
        if groups[index].error:
            continue
        if fence_error:
            groups[index].error = (
                "line " + String(open_line) + ": " + fence_error
            )
        elif not closed:
            groups[index].error = (
                "line " + String(open_line) + ": unterminated code fence"
            )
        else:
            groups[index].blocks.append(
                Block(fence.value().is_global, body^, open_line + 1)
            )

    doctests = List[Doctest]()
    for group in groups:
        doctests.append(_generate(source, group))


def _fence_char(text: String) -> String:
    """Returns the fence character text starts with, or an empty string."""
    if text.startswith("`"):
        return "`"
    if text.startswith("~"):
        return "~"
    return ""


def _char_run(text: String, char: String) -> Int:
    """Returns how often char repeats at the start of text."""
    if char == "":
        return 0
    var n = 0
    while n < text.byte_length() and String(text[byte=n]) == char:
        n += 1
    return n


def _docstring_toggles(line: String, mut delimiter: String) -> Int:
    """Returns how many docstrings open or close on line.

    `delimiter` holds the triple quote of the open docstring, or is empty
    outside one. Inside a docstring only its own delimiter closes it, so
    triple single quotes within a triple double-quoted docstring do not
    change the scope, and vice versa.
    """
    var toggles = 0
    var pos = 0
    while True:
        var at: Int
        if delimiter != "":
            at = line.find(delimiter, pos)
        else:
            var double = line.find('"""', pos)
            var single = line.find("'''", pos)
            if double < 0 or (single >= 0 and single < double):
                at = single
                delimiter = "'''"
            else:
                at = double
                delimiter = '"""'
            if at < 0:
                delimiter = ""
                return toggles
            toggles += 1
            pos = at + 3
            continue
        if at < 0:
            return toggles
        delimiter = ""
        toggles += 1
        pos = at + 3


def _dedent(line: String, indent: String) -> String:
    if line.startswith(indent):
        return String(line[byte = indent.byte_length() :])
    return String(line.lstrip())


def _generate(source: String, group: Group, out result: Doctest):
    result = Doctest(
        source, group.name, group.line, String(), List[Int](), group.error
    )
    if result.error:
        return

    var code = String()
    var has_main = False
    var has_body = False
    for block in group.blocks:
        if not block.is_global:
            has_body = True
            continue
        for j in range(len(block.lines)):
            var text = block.lines[j]
            if text.startswith(MAIN_DEF):
                has_main = True
            code += text + "\n"
            result.line_map.append(block.first_line + j)

    if has_main and has_body:
        result.error = (
            "global blocks define `def main` and non-global blocks exist;"
            " make every block global or drop the `def main`"
        )
        result.line_map.clear()
        return

    if not has_main:
        code += "def main() raises:\n"
        result.line_map.append(0)
        var has_statement = False
        for block in group.blocks:
            if block.is_global:
                continue
            for j in range(len(block.lines)):
                var text = block.lines[j]
                if String(text.strip()).byte_length() == 0:
                    code += "\n"
                else:
                    code += BODY_INDENT + text + "\n"
                    has_statement = True
                result.line_map.append(block.first_line + j)
        if not has_statement:
            code += BODY_INDENT + "pass\n"
            result.line_map.append(0)

    result.code = code^


def remap_locations(
    output: String, generated_path: String, doctest: Doctest, out result: String
):
    """Rewrites `generated_path:LINE` locations in compiler output.

    Each location that maps to a source line becomes `source:LINE'`, so
    diagnostics point at the documentation instead of the generated file.
    Locations on generated-only lines are left unchanged.
    """
    result = String()
    var prefix = generated_path + ":"
    var size = output.byte_length()
    var pos = 0
    while True:
        var at = output.find(prefix, pos)
        if at < 0:
            result += String(output[byte=pos:])
            break
        result += String(output[byte=pos:at])
        var digits_start = at + prefix.byte_length()
        var digits_end = digits_start
        while digits_end < size and _is_digit(String(output[byte=digits_end])):
            digits_end += 1
        var mapped = 0
        if digits_end > digits_start:
            try:
                var line = atol(output[byte=digits_start:digits_end])
                if line >= 1 and line <= len(doctest.line_map):
                    mapped = doctest.line_map[line - 1]
            except:
                pass
        if mapped > 0:
            result += doctest.source + ":" + String(mapped)
        else:
            result += String(output[byte=at:digits_end])
        pos = digits_end


def _is_digit(char: String) -> Bool:
    return char >= "0" and char <= "9" and char.byte_length() == 1
