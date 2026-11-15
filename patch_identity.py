#!/usr/bin/env python3
"""Recognize a backport whose surrounding context changed on this branch."""
import email
from email.header import decode_header, make_header
from email.utils import parseaddr
from pathlib import Path
import re
import subprocess
import sys


def changes(diff):
    """Keep paths, modes and exact changed lines; discard only hunk context."""
    files = []
    current = None
    old = new = 0
    index = b""
    for line in diff.splitlines():
        if line.startswith(b"diff --git "):
            current = [line, [], []]
            files.append(current)
            old = new = 0
        elif current is None:
            continue
        elif line.startswith(b"index "):
            index = line
        elif line == b"GIT binary patch" or line.startswith(b"Binary files "):
            current[1].append(index)
        elif line.startswith((b"old mode ", b"new mode ", b"new file mode ",
                              b"deleted file mode ", b"rename from ", b"rename to ")):
            current[1].append(line)
        elif line.startswith(b"@@ "):
            match = re.match(rb"@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@", line)
            if match:
                old, new = (int(n) if n is not None else 1 for n in match.groups())
        elif old or new:
            if line.startswith(b"+"):
                current[2].append(line)
                new -= 1
            elif line.startswith(b"-"):
                current[2].append(line)
                old -= 1
            elif line.startswith(b" "):
                old -= 1
                new -= 1
    return sorted(files)


def matches(patch_path, commit):
    patch = Path(patch_path).read_bytes()
    message = email.message_from_bytes(patch)
    subject = str(make_header(decode_header(message.get("Subject", ""))))
    subject = re.sub(r"^(?:\[PATCH[^\]]*\]\s*)+", "", subject)
    author = parseaddr(message.get("From", ""))[1]
    metadata = subprocess.check_output(
        ["git", "show", "-s", "--format=%s%n%ae", commit], text=True).splitlines()
    if metadata != [subject, author]:
        return False
    actual = subprocess.check_output([
        "git", "show", "--format=", "--no-ext-diff", "--binary", "--full-index",
        "--unified=0", commit,
    ])
    expected_changes = changes(patch)
    return bool(expected_changes) and expected_changes == changes(actual)


if __name__ == "__main__":
    sys.exit(0 if matches(*sys.argv[1:]) else 1)
