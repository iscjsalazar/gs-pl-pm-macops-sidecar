#!/usr/bin/env python3
"""Fingerprint de source + assets para la receta unit-macdata (local y remoto)."""
import hashlib
import os
import pathlib
import sys


def main() -> int:
    root = pathlib.Path(sys.argv[1]).resolve()
    assets = [ln.strip() for ln in open(sys.argv[2], encoding="utf-8") if ln.strip()]
    exclude_dirs = {".git", "bin", "obj", "TestResults", "artifacts", ".vs", ".idea"}
    entries = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = pathlib.Path(dirpath).relative_to(root)
        parts = rel_dir.parts
        if parts and parts[0] == "containers":
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in exclude_dirs and not d.startswith("._")]
        for name in filenames:
            if name == ".env" or name.startswith("._"):
                continue
            p = pathlib.Path(dirpath) / name
            rel = str(p.relative_to(root)).replace("\\", "/")
            if any(part in exclude_dirs for part in pathlib.Path(rel).parts):
                continue
            entries.append(rel)
    for a in assets:
        if a not in entries:
            entries.append(a)
    entries = sorted(set(entries))
    h = hashlib.sha256()
    for rel in entries:
        p = root / rel
        if not p.is_file():
            print(f"missing:{rel}", file=sys.stderr)
            return 3
        dig = hashlib.sha256(p.read_bytes()).hexdigest()
        size = p.stat().st_size
        mode = "x" if os.access(p, os.X_OK) else "-"
        h.update(f"{rel}|F|{mode}|{size}|{dig}\n".encode())
    print(h.hexdigest())
    ah = hashlib.sha256()
    for rel in sorted(assets):
        p = root / rel
        dig = hashlib.sha256(p.read_bytes()).hexdigest()
        ah.update(f"{rel}|{p.stat().st_size}|{dig}\n".encode())
    print(ah.hexdigest())
    n = 0
    c = root / "containers"
    if c.is_dir():
        for _dp, _dn, fn in os.walk(c):
            n += len(fn)
    print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
