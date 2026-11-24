#!/usr/bin/env python3
"""Check the repository's source rules: patterns that must not appear, or only in named files.

    Scripts/check-source-rules.py [--root DIR] [--rules DIR] [--rule ID]... [--list]

Rules live in Scripts/source-rules/*.toml, one table per rule:

    [[rule]]
    id = "podcast-duration-copy-one-caller"     # unique, kebab-case
    why = "Printed on failure: what breaks if this pattern spreads."
    files = ["App/Whirr/Views/**/*.swift"]      # globs relative to the root; each must match
    exclude = ["App/Whirr/Views/Debug/**"]      # optional; each must match a file in `files`
    forbid = 'PodcastCopy\\.duration\\(seconds:' # a Python regex, MULTILINE
    allow = ["App/Whirr/Views/Downloads/DownloadsViewPresentation.swift"]  # optional
    at_most = 1                                 # optional: matches allowed per file (default 0)
    text = "code"                               # "code" (default), "code-no-strings" or "raw"
    example = 'Text(PodcastCopy.duration(seconds: 90))'   # must match; a string or a list
    ok = ['PodcastCopy.durationText(90)']       # optional: must not match

Text modes. "code" blanks comments and the `#if PERF_INVESTIGATION` branch of a conditional block
(its `#else` branch is production code and stays), keeping string literals and line numbers.
"code-no-strings" also blanks string literal contents, keeping interpolated code. "raw" is the
file as written.

The check fails closed, because a rule that reads nothing passes forever:
- every `files` and `exclude` glob must match at least one file;
- every `allow` glob must match a file in the rule's set, and one of those files must still
  contain a match, so an allowance outlives neither its file nor its reason;
- every `example` must match and every `ok` must not, in the rule's text mode.

Standard library only (tomllib needs Python 3.11), so it runs on the per-push Linux CI lane.
"""

from __future__ import annotations

import argparse
import functools
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RULES = Path(__file__).resolve().parent / "source-rules"
TEXT_MODES = ("code", "code-no-strings", "raw")
RULE_KEYS = {"id", "why", "files", "exclude", "forbid", "allow", "at_most", "text", "example", "ok"}
ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SKIPPED_DIRECTORIES = {".git", ".build", ".swiftpm", "DerivedData", "build"}


class RuleError(Exception):
    """A rule file that cannot be trusted to check anything."""


# MARK: - Stripping


_CODE_TOKEN = re.compile(r'//|/\*|(#*)("""|")|[()]')
_BLOCK_TOKEN = re.compile(r"/\*|\*/")


def _blank(text: str) -> str:
    return re.sub(r"[^\n]", " ", text)


def strip_swift(source: str, keep_strings: bool = True) -> str:
    """Comments blanked (and, unless `keep_strings`, string contents), same length and lines.

    Handles nested block comments, multi-line and raw (`#"…"#`) strings, and interpolation
    (`\\(…)`, `\\#(…)`), whose code is lexed as code so a string inside it cannot end the outer one.
    """
    out: list[str] = []
    position = 0
    # Each frame is the paren depth of an interpolation's code, with the string it returns to.
    stack: list[tuple[int, int, bool]] = []  # (paren depth, hashes, multiline)
    depth = 0
    length = len(source)

    def emit_code(end: int) -> None:
        nonlocal position
        out.append(source[position:end])
        position = end

    def skip_blank(end: int, keep: bool = False) -> None:
        nonlocal position
        piece = source[position:end]
        out.append(piece if keep else _blank(piece))
        position = end

    def lex_string(hashes: int, multiline: bool) -> bool:
        """Consume string contents from `position`; True if an interpolation was entered."""
        nonlocal position
        closer = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        token = re.compile(re.escape(escape) + "|" + re.escape(closer) + ("" if multiline else "|\n"))
        while True:
            match = token.search(source, position)
            if match is None:
                skip_blank(length, keep_strings)
                return False
            if match.group() == "\n":  # an unterminated single-line string ends at the line
                skip_blank(match.start(), keep_strings)
                return False
            if match.group() == closer:
                skip_blank(match.start(), keep_strings)
                emit_code(match.end())
                return False
            # An escape: interpolation opens code, anything else skips one character.
            after = match.end()
            if after < length and source[after] == "(":
                skip_blank(match.start(), keep_strings)
                emit_code(after + 1)
                stack.append((1, hashes, multiline))
                return True
            skip_blank(min(after + 1, length), keep_strings)

    while position < length:
        if stack:
            match = _CODE_TOKEN.search(source, position)
            if match is None:
                emit_code(length)
                break
            text = match.group()
            if text in "()":
                emit_code(match.end())
                paren, hashes, multiline = stack[-1]
                paren += 1 if text == "(" else -1
                if paren == 0:
                    stack.pop()
                    lex_string(hashes, multiline)
                else:
                    stack[-1] = (paren, hashes, multiline)
                continue
        else:
            match = _CODE_TOKEN.search(source, position)
            while match is not None and match.group() in "()":
                match = _CODE_TOKEN.search(source, match.end())
            if match is None:
                emit_code(length)
                break
            text = match.group()
        if text == "//":
            emit_code(match.start())
            end = source.find("\n", position)
            skip_blank(length if end < 0 else end)
        elif text == "/*":
            emit_code(match.start())
            depth = 0
            cursor = position
            while True:
                inner = _BLOCK_TOKEN.search(source, cursor)
                if inner is None:
                    cursor = length
                    break
                depth += 1 if inner.group() == "/*" else -1
                cursor = inner.end()
                if depth == 0:
                    break
            skip_blank(cursor)
        else:  # a string opener, with any raw-string hashes
            emit_code(match.end())
            lex_string(len(match.group(1)), match.group(2) == '"""')
    return "".join(out)


_DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def strip_perf_investigation(text: str) -> str:
    """Blank the `#if PERF_INVESTIGATION` branch of each conditional, keeping its `#else`."""
    lines = text.split("\n")
    blanking = False
    depth = 0  # nesting inside the blanked branch
    for index, line in enumerate(lines):
        directive = _DIRECTIVE.match(line)
        if not blanking:
            if directive and directive.group(1) == "if" and directive.group(2).strip() == "PERF_INVESTIGATION":
                blanking, depth = True, 0
                lines[index] = _blank(line)
            continue
        if directive:
            kind = directive.group(1)
            if kind == "if":
                depth += 1
            elif kind == "endif":
                if depth == 0:
                    blanking = False
                else:
                    depth -= 1
            elif depth == 0 and kind in ("else", "elseif"):
                blanking = False
        lines[index] = _blank(line)
    return "\n".join(lines)


def rule_text(source: str, mode: str) -> str:
    if mode == "raw":
        return source
    return strip_perf_investigation(strip_swift(source, keep_strings=mode == "code"))


# MARK: - Globs and files


@functools.cache
def glob_regex(pattern: str) -> re.Pattern[str]:
    """`**/` any directories (or none), `*` within one component, `?`, `[…]` and `{a,b}`."""
    out, index = [], 0
    while index < len(pattern):
        char = pattern[index]
        if pattern.startswith("**/", index):
            out.append("(?:.*/)?")
            index += 3
        elif pattern.startswith("**", index):
            out.append(".*")
            index += 2
        elif char == "*":
            out.append("[^/]*")
            index += 1
        elif char == "?":
            out.append("[^/]")
            index += 1
        elif char == "[":
            end = pattern.index("]", index + 1)
            out.append(pattern[index : end + 1])
            index = end + 1
        elif char == "{":
            end = pattern.index("}", index)
            out.append("(?:" + "|".join(re.escape(part) for part in pattern[index + 1 : end].split(",")) + ")")
            index = end + 1
        else:
            out.append(re.escape(char))
            index += 1
    return re.compile("".join(out) + r"\Z")


def repository_files(root: Path) -> list[str]:
    """Tracked and untracked-but-not-ignored files under `root`, or a walk where there is no git."""
    try:
        listed = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            check=True, capture_output=True,
        ).stdout.decode()
        return sorted(path for path in listed.split("\0") if path and (root / path).is_file())
    except (subprocess.CalledProcessError, FileNotFoundError):
        found = []
        for directory, subdirectories, files in os.walk(root):
            subdirectories[:] = [d for d in subdirectories if d not in SKIPPED_DIRECTORIES]
            for name in files:
                found.append(str((Path(directory) / name).relative_to(root)))
        return sorted(found)


# MARK: - Rules


@dataclass
class Rule:
    id: str
    why: str
    files: list[str]
    forbid: re.Pattern[str]
    source: str
    exclude: list[str] = field(default_factory=list)
    allow: list[str] = field(default_factory=list)
    at_most: int = 0
    text: str = "code"
    example: list[str] = field(default_factory=list)
    ok: list[str] = field(default_factory=list)


def _string_list(table: dict, key: str, where: str, required: bool = False) -> list[str]:
    value = table.get(key, [])
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise RuleError(f"{where}: `{key}` must be a string or a list of non-empty strings")
    if required and not value:
        raise RuleError(f"{where}: `{key}` is required")
    return value


def load_rules(rules_directory: Path) -> list[Rule]:
    paths = sorted(rules_directory.glob("*.toml"))
    if not paths:
        raise RuleError(f"no rule files in {rules_directory}")
    rules: list[Rule] = []
    seen: dict[str, str] = {}
    for path in paths:
        with path.open("rb") as handle:
            try:
                document = tomllib.load(handle)
            except tomllib.TOMLDecodeError as error:
                raise RuleError(f"{path.name}: {error}") from error
        unknown_top = set(document) - {"rule"}
        if unknown_top:
            raise RuleError(f"{path.name}: unknown top-level keys {sorted(unknown_top)}")
        for number, table in enumerate(document.get("rule", []), start=1):
            where = f"{path.name} rule {number}"
            unknown = set(table) - RULE_KEYS
            if unknown:
                raise RuleError(f"{where}: unknown keys {sorted(unknown)}")
            rule_id = table.get("id")
            if not isinstance(rule_id, str) or not ID_PATTERN.match(rule_id):
                raise RuleError(f"{where}: `id` must be kebab-case")
            where = f"{path.name} [{rule_id}]"
            if rule_id in seen:
                raise RuleError(f"{where}: duplicate id, first in {seen[rule_id]}")
            seen[rule_id] = path.name
            why = table.get("why")
            if not isinstance(why, str) or not why.strip():
                raise RuleError(f"{where}: `why` is required")
            forbid = table.get("forbid")
            if not isinstance(forbid, str) or not forbid:
                raise RuleError(f"{where}: `forbid` is required")
            try:
                pattern = re.compile(forbid, re.MULTILINE)
            except re.error as error:
                raise RuleError(f"{where}: `forbid` is not a valid regex: {error}") from error
            mode = table.get("text", "code")
            if mode not in TEXT_MODES:
                raise RuleError(f"{where}: `text` must be one of {', '.join(TEXT_MODES)}")
            at_most = table.get("at_most", 0)
            if not isinstance(at_most, int) or isinstance(at_most, bool) or at_most < 0:
                raise RuleError(f"{where}: `at_most` must be a non-negative integer")
            example = _string_list(table, "example", where, required=True)
            rules.append(
                Rule(
                    id=rule_id, why=why.strip(), source=path.name, forbid=pattern,
                    files=_string_list(table, "files", where, required=True),
                    exclude=_string_list(table, "exclude", where),
                    allow=_string_list(table, "allow", where),
                    at_most=at_most, text=mode, example=example,
                    ok=_string_list(table, "ok", where),
                ))
    return rules


@dataclass
class Report:
    violations: list[str] = field(default_factory=list)
    broken: list[str] = field(default_factory=list)
    annotations: list[str] = field(default_factory=list)
    files_read: set[str] = field(default_factory=set)


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def check(rules: list[Rule], root: Path, files: list[str]) -> Report:
    report = Report()
    texts: dict[tuple[str, str], str] = {}

    def text_of(path: str, mode: str) -> str:
        key = (path, mode)
        if key not in texts:
            source = (root / path).read_text(encoding="utf-8", errors="replace")
            texts[key] = rule_text(source, mode)
            report.files_read.add(path)
        return texts[key]

    for rule in rules:
        label = f"[{rule.id}] ({rule.source})"
        for snippet in rule.example:
            if not rule.forbid.search(rule_text(snippet, rule.text)):
                report.broken.append(f"{label}: example does not match the rule: {snippet!r}")
        for snippet in rule.ok:
            if rule.forbid.search(rule_text(snippet, rule.text)):
                report.broken.append(f"{label}: `ok` snippet matches the rule: {snippet!r}")

        in_scope: set[str] = set()
        for pattern in rule.files:
            matched = [path for path in files if glob_regex(pattern).match(path)]
            if not matched:
                report.broken.append(f"{label}: `files` glob matches nothing: {pattern}")
            in_scope.update(matched)
        for pattern in rule.exclude:
            matched = {path for path in in_scope if glob_regex(pattern).match(path)}
            if not matched:
                report.broken.append(f"{label}: `exclude` glob matches no file in scope: {pattern}")
            in_scope -= matched
        allowed: set[str] = set()
        allow_globs = {pattern: {p for p in in_scope if glob_regex(pattern).match(p)} for pattern in rule.allow}
        for pattern, matched in allow_globs.items():
            if not matched:
                report.broken.append(f"{label}: `allow` glob matches no file in scope: {pattern}")
            allowed |= matched

        for path in sorted(in_scope):
            text = text_of(path, rule.text)
            matches = list(rule.forbid.finditer(text))
            if path in allowed:
                continue
            if len(matches) <= rule.at_most:
                continue
            for match in matches[rule.at_most :] if rule.at_most else matches:
                line = line_of(text, match.start())
                snippet = text.split("\n")[line - 1].strip()
                report.violations.append(f"{path}:{line}: [{rule.id}] {snippet}\n    why: {rule.why}")
                report.annotations.append(
                    f"::error file={path},line={line},title=source rule {rule.id}::{rule.why}")
        for pattern, matched in allow_globs.items():
            if matched and not any(rule.forbid.search(text_of(path, rule.text)) for path in matched):
                report.broken.append(
                    f"{label}: `allow` entry is stale, no file it names matches any more: {pattern}")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--rules", type=Path, default=DEFAULT_RULES)
    parser.add_argument("--rule", action="append", default=[], help="check only this rule id")
    parser.add_argument("--list", action="store_true", help="list rule ids and stop")
    arguments = parser.parse_args(argv)

    try:
        rules = load_rules(arguments.rules)
    except RuleError as error:
        print(f"source rules: {error}", file=sys.stderr)
        return 2
    if arguments.list:
        for rule in rules:
            print(f"{rule.id}\t{rule.source}\t{rule.why}")
        return 0
    if arguments.rule:
        unknown = set(arguments.rule) - {rule.id for rule in rules}
        if unknown:
            print(f"source rules: no rule with id {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        rules = [rule for rule in rules if rule.id in arguments.rule]

    root = arguments.root.resolve()
    report = check(rules, root, repository_files(root))
    if report.broken:
        print("source rules that cannot be trusted (fix the rule, not the code):", file=sys.stderr)
        for line in report.broken:
            print(f"  {line}", file=sys.stderr)
    if report.violations:
        print(f"{len(report.violations)} source rule violation(s):", file=sys.stderr)
        for line in report.violations:
            print(line, file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            for line in report.annotations:
                print(line)
    if report.broken or report.violations:
        return 1
    print(f"source rules: {len(rules)} rules over {len(report.files_read)} files, no violations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
