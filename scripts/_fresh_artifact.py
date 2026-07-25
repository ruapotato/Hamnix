"""scripts/_fresh_artifact.py — ALWAYS-OVERWRITE contract, Python builders.

The Python twin of scripts/_fresh_artifact.sh; see that file for the full
rationale. In one line: running a build script ALWAYS produces a fresh
artifact, and the output is deleted BEFORE the build starts so a build that
fails halfway leaves nothing behind that could be mistaken for valid.

    from _fresh_artifact import fresh_artifact
    fresh_artifact("[build_rootfs_img]", out_path)

HAMNIX_REUSE_ARTIFACTS=1 opts out (loudly).
"""

import os
import shutil
import sys
import time
from pathlib import Path


def reuse_requested() -> bool:
    """True when the caller opted out via HAMNIX_REUSE_ARTIFACTS=1."""
    return os.environ.get("HAMNIX_REUSE_ARTIFACTS", "0") == "1"


def _age_str(p: Path) -> str:
    try:
        t = p.stat().st_mtime
    except OSError:
        return "ABSENT"
    age = max(0, time.time() - t)
    d, rem = divmod(int(age), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    built = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
    return f"{d}d{h:02d}h{m:02d}m old (built {built})"


def _loud(tag: str, lines) -> None:
    bar = f"{tag} " + "#" * 60
    print(bar, file=sys.stderr)
    for line in lines:
        print(f"{tag} ## {line}", file=sys.stderr)
    print(bar, file=sys.stderr, flush=True)


def fresh_artifact(tag: str, *paths) -> None:
    """Delete every named output so this build cannot reuse or half-update it.

    With HAMNIX_REUSE_ARTIFACTS=1 the files are kept and a loud banner is
    printed instead.
    """
    ps = [Path(p) for p in paths if p]
    if not ps:
        return
    if reuse_requested():
        present = [p for p in ps if p.exists() or p.is_symlink()]
        if present:
            _loud(tag, [
                "HAMNIX_REUSE_ARTIFACTS=1 — NOT deleting existing outputs:",
            ] + [f"    {p}  {_age_str(p)}" for p in present] + [
                "  A build that fails halfway will leave the OLD artifact in",
                "  place looking valid. Any verdict downstream of this run may",
                "  describe an OLD build. Unset HAMNIX_REUSE_ARTIFACTS to get",
                "  the always-overwrite contract back.",
            ])
        return
    for p in ps:
        if p.is_symlink() or p.is_file():
            print(f"{tag} overwrite: removing previous {p} ({_age_str(p)})",
                  flush=True)
            p.unlink()
        elif p.is_dir():
            print(f"{tag} overwrite: removing previous {p}/ ({_age_str(p)})",
                  flush=True)
            shutil.rmtree(p)
