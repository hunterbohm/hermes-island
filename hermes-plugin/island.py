"""Runs Hermes Island's command line, on this Mac or through a transport such as ssh to the Mac that runs it.

Every command is a fixed argument list. Over a transport, the island's command is quoted with shlex into the one
remote command string that ssh takes last; nothing runs through a local shell.
"""

from __future__ import annotations

import json
import os
import platform
import shlex
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

APP = "/Applications/Hermes Island.app/Contents/MacOS/HermesIsland"
REPO = "https://github.com/hunterbohm/hermes-island"
DEFAULT_RING = 30
LONGEST_RING = 120
# What `HermesIsland call` exit codes mean for the caller.
NEXT_STEP = {0: "done", 3: "text instead", 4: "busy, try later", 5: "could not ring"}


@dataclass
class Island:
    app: str = APP
    transport: list[str] = field(default_factory=list)

    @classmethod
    def from_settings(cls, get: Callable[[str], object]) -> "Island":
        """`get` reads one plugin setting: `app_path`, `transport`."""
        app = str(get("app_path") or "").strip() or APP
        return cls(app=app, transport=shlex.split(str(get("transport") or "")))

    @property
    def where(self) -> str:
        return "this Mac" if not self.transport else f"through `{shlex.join(self.transport)}`"

    def missing(self) -> Optional[str]:
        """Why there is no island to reach, or None. Over a transport the far side is only checked by running."""
        if self.transport:
            return None
        if platform.system() != "Darwin":
            return "Hermes Island runs on macOS. Set the plugin's transport setting to reach the Mac that runs it."
        if not os.access(self.app, os.X_OK):
            return f"Hermes Island is not installed at {self.app}. Run `hermes island build`, or set app_path."
        return None

    def command(self, arguments: list[str]) -> list[str]:
        if not self.transport:
            return [self.app, *arguments]
        return [*self.transport, shlex.join([self.app, *arguments])]

    def knows(self, usage: str) -> bool:
        """Whether this build of the app has a command. An older build takes an unknown word for a launch."""
        try:
            return usage in self.run(["--help"], timeout=20).stderr
        except (subprocess.TimeoutExpired, OSError):
            return False

    def run(self, arguments: list[str], stdin: Optional[str] = None, timeout: float = 30) -> subprocess.CompletedProcess:
        return subprocess.run(self.command(arguments), input=stdin or "", capture_output=True, text=True, timeout=timeout,
                              check=False)


def json_lines(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def call_back(island: Island, about: str, result: str, ring_seconds: object = None, caller: str = "Hermes") -> dict:
    """Rings the island and waits for the call to end. Returns the last status, its detail, the exit code and what
    the caller should do next."""
    about, result = (about or "").strip(), (result or "").strip()
    if not about or not result:
        return {"status": "failed", "detail": "about and result are both needed", "exit_code": 2, "next": "fix the call"}
    if reason := island.missing():
        return {"status": "failed", "detail": reason, "exit_code": 5, "next": NEXT_STEP[5]}
    if not island.knows("HermesIsland call "):
        return {"status": "failed", "detail": "this Hermes Island is too old for call backs", "exit_code": 5,
                "next": NEXT_STEP[5]}
    try:
        ring = int(float(ring_seconds)) if ring_seconds not in (None, "") else DEFAULT_RING
    except (TypeError, ValueError):
        ring = DEFAULT_RING
    ring = max(5, min(LONGEST_RING, ring))
    arguments = ["call", "--from", caller or "Hermes", "--about", about, "--ring", str(ring)]
    # The talk that follows an answer can run a few minutes, so the wait is long.
    try:
        done = island.run(arguments, stdin=result, timeout=ring + 330)
    except subprocess.TimeoutExpired:
        return {"status": "failed", "detail": "the call never finished", "exit_code": 5, "next": NEXT_STEP[5]}
    except OSError as error:
        return {"status": "failed", "detail": str(error), "exit_code": 5, "next": NEXT_STEP[5]}
    rows = json_lines(done.stdout)
    last = rows[-1] if rows else {}
    status = str(last.get("status") or "failed")
    detail = str(last.get("detail") or (done.stderr.strip()[-300:] if not rows else ""))
    if done.returncode == 255 and island.transport and not rows:
        detail = "the Mac didn't answer over the transport: " + detail
    code = done.returncode if done.returncode in NEXT_STEP else 5
    return {"status": status, "detail": detail, "exit_code": done.returncode, "next": NEXT_STEP[code]}


def status(island: Island) -> list[tuple[str, str]]:
    """Rows of (what, state) for `hermes island status`."""
    rows = [("island", island.where), ("app", island.app)]
    if reason := island.missing():
        return rows + [("problem", reason)]
    checks = [
        ("talks go to", ["agent"]),
        ("busy now", ["call", "--check"]),
        ("open at login", ["--login-status"]),
    ]
    for label, arguments in checks:
        if arguments == ["agent"] and not island.knows("HermesIsland agent"):
            rows.append((label, "unknown: this Hermes Island is too old, run `hermes island build`"))
            continue
        try:
            done = island.run(arguments, timeout=20)
        except (subprocess.TimeoutExpired, OSError) as error:
            rows.append((label, f"no answer ({error})"))
            continue
        out = done.stdout.strip()
        if label == "talks go to":
            agent = (json_lines(out) or [{}])[0].get("agent") or {}
            host = agent.get("host")
            out = f"{agent.get('name', 'nobody')} ({shlex.join(agent.get('command') or [])}" + (f" on {host})" if host else " here)")
        elif label == "busy now":
            out = "yes" if done.returncode == 4 else "no" if done.returncode == 0 else out or f"exit {done.returncode}"
        else:
            out = "on" if "launch agent: enabled" in out else "off"
        rows.append((label, out))
    rows.append(("running", "yes" if _running(island) else "no: open Hermes Island, or call backs fail"))
    return rows


def _running(island: Island) -> bool:
    probe = ["/usr/bin/pgrep", "-x", "HermesIsland"]
    command = probe if not island.transport else [*island.transport, shlex.join(probe)]
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=20, check=False).returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def setup(island: Island, host: Optional[str]) -> tuple[int, str]:
    """Points the island's talks at Hermes: `hermes acp` on the island's Mac, or over ssh on `host`."""
    if reason := island.missing():
        return 1, reason
    if not island.knows("HermesIsland agent"):
        return 1, "This Hermes Island is too old for setup. Run `hermes island build` first."
    arguments = ["agent", "--hermes"] + (["--host", host] if host else [])
    done = island.run(arguments, timeout=30)
    return done.returncode, (done.stdout.strip() or done.stderr.strip())


def source_checkout(plugin_dir: Path) -> Optional[Path]:
    """The app's source: the repository this plugin folder sits in, when it is a full checkout."""
    root = plugin_dir.resolve().parent
    return root if (root / "scripts" / "build-app.sh").is_file() else None


def build_steps(root: Path) -> list[list[str]]:
    scripts = root / "scripts"
    return [[str(scripts / "fetch-deps.sh")], [str(scripts / "test.sh")], [str(scripts / "build-app.sh")]]
