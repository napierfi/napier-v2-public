#!/usr/bin/env python3
"""Prepare a pinned snapshot from two LOCAL checkouts; never fetch, commit or push."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from dataclasses import dataclass

SOURCE_SHA = "4475064276a0fc782e4a18a6fe0be3e01381bd63"
PUBLIC_BASE = "9a3cb443574d8979a1a2bb46e92b6bf5936489c5"
TREES = {
    "src": "e12b96014c892fd082344bed96b21c01b8e4d637",
    "test": "87dadc128fb853cf840bd996ee0b9c2786b70c88",
    "script": "e71022751aa743c0a604007cb636e3871a1532d5",
}
ROOTS = tuple(TREES)
FILES = (".env.example", ".gitignore", "foundry.toml", "package.json",
         "pnpm-lock.yaml", "slither.config.json")
SECRET_PATTERNS = (
    rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b",
    rb"\bgithub_pat_[A-Za-z0-9_]{50,}\b",
    rb"\bAKIA[A-Z0-9]{16}\b",
)


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "--no-replace-objects", "-C", str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise RuntimeError("Git command failed: " + " ".join(args) + "\n" +
                           result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def selected(path: str) -> bool:
    p = PurePosixPath(path)
    if p.is_absolute() or str(p) != path or ".." in p.parts or ".git" in p.parts:
        return False
    return path in FILES or any(path.startswith(root + "/") for root in ROOTS)


@dataclass(frozen=True)
class Entry:
    mode: str
    sha: str


def entries(repo: Path, revision: str) -> dict[str, Entry]:
    output: dict[str, Entry] = {}
    for record in git(repo, "ls-tree", "-r", "-z", revision).split(b"\0"):
        if not record:
            continue
        meta, name = record.split(b"\t", 1)
        path = name.decode("utf-8")
        if not selected(path):
            continue
        mode, kind, sha = meta.decode("ascii").split()
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise RuntimeError("Refusing a symlink/submodule/special entry: " + path)
        output[path] = Entry(mode, sha)
    return output


def blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def read_payload(repo: Path, source: dict[str, Entry]) -> dict[str, bytes]:
    payload = {}
    for path, entry in source.items():
        data = git(repo, "cat-file", "blob", entry.sha)
        if blob_id(data) != entry.sha:
            raise RuntimeError("Blob verification failed: " + path)
        if any(re.search(pattern, data) for pattern in SECRET_PATTERNS):
            raise RuntimeError("Potential credential; review locally before publishing: " + path)
        payload[path] = data
    return payload


def changes(source: dict[str, Entry], target: dict[str, Entry]) -> dict[str, str]:
    result = {}
    for path in sorted(source.keys() | target.keys()):
        if path not in source:
            # Only replace complete code trees; do not remove unrelated root files.
            if any(path.startswith(root + "/") for root in ROOTS):
                result[path] = "D"
        elif path not in target:
            result[path] = "A"
        elif source[path] != target[path]:
            result[path] = "M"
    return result


def preflight(target: Path, source: dict[str, Entry], previous: dict[str, Entry]) -> None:
    for name in source.keys() | previous.keys():
        path = target / name
        for component in [path, *path.parents]:
            if component == target:
                break
            if component.is_symlink():
                raise RuntimeError("Refusing a symlink in destination: " + name)
        if path.exists() and not path.is_file():
            raise RuntimeError("Destination is not a regular file: " + name)
        if path.exists() and name not in previous:
            raise RuntimeError("Refusing to overwrite an untracked/ignored file: " + name)


def apply_snapshot(target: Path, source: dict[str, Entry], previous: dict[str, Entry],
                   payload: dict[str, bytes]) -> None:
    preflight(target, source, previous)
    plan = changes(source, previous)
    for name, action in plan.items():
        path = target / name
        if action == "D":
            path.unlink()
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload[name])
            path.chmod(0o755 if source[name].mode == "100755" else 0o644)
    for name, entry in source.items():
        path = target / name
        actual_mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        if blob_id(path.read_bytes()) != entry.sha or actual_mode != entry.mode:
            raise RuntimeError("Post-copy verification failed: " + name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Local private repository checkout")
    parser.add_argument("--target", default=Path.cwd(), type=Path, help="Local public PR checkout")
    parser.add_argument("--apply", action="store_true", help="Write working-tree changes (default: dry run)")
    parser.add_argument("--license-reviewed", action="store_true",
                        help="Confirm that the publication's license discrepancy has been reviewed")
    args = parser.parse_args()
    source = Path(git(args.source, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    target = Path(git(args.target, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if source == target:
        raise RuntimeError("Source and public target must be distinct checkouts")
    git(source, "rev-parse", "--verify", SOURCE_SHA + "^{commit}")
    git(target, "merge-base", "--is-ancestor", PUBLIC_BASE, "HEAD")
    if git(target, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Target must have a clean working tree and index")
    if git(target, "diff", "--name-only", PUBLIC_BASE, "HEAD", "--", *ROOTS, *FILES):
        raise RuntimeError("Public code changed since the pinned base; reconcile it manually first")
    for root, expected in TREES.items():
        actual = git(source, "rev-parse", SOURCE_SHA + ":" + root).decode().strip()
        if actual != expected:
            raise RuntimeError("Unexpected source tree: " + root)
    src = entries(source, SOURCE_SHA)
    dst = entries(target, "HEAD")
    if not all(name in src for name in FILES):
        raise RuntimeError("The pinned source is missing a required build/config file")
    payload = read_payload(source, src)
    preflight(target, src, dst)
    plan = changes(src, dst)
    for name, action in plan.items():
        print(action + " " + name)
    print(f"{len(plan)} changes; {len(src)} source files verified; source {SOURCE_SHA}")
    if not args.apply:
        print("DRY RUN: no files changed. Review publication and licensing before --apply.")
        return 0
    if not args.license_reviewed:
        raise RuntimeError("Resolve/document the license discrepancy, then pass --license-reviewed")
    branch = git(target, "symbolic-ref", "--short", "HEAD").decode().strip()
    if branch in {"main", "master"}:
        raise RuntimeError("Switch to the public PR branch before applying")
    apply_snapshot(target, src, dst, payload)
    print("Working tree updated and verified. Nothing was staged, committed, pushed, or deployed.")
    print("Review git diff; complete documentation/licensing review and run Solidity tests.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, UnicodeError, ValueError) as exc:
        print("ERROR: " + str(exc), file=sys.stderr)
        sys.exit(1)
