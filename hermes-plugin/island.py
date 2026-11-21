"""Runs Hermes Island's command line, on this Mac or through a transport such as ssh to the Mac that runs it.

Every command is a fixed argument list. Over a transport, the island's command is quoted with shlex into the one
remote command string that ssh takes last; nothing runs through a local shell.
"""

from __future__ import annotations

import json
import os
import platform
import shlex
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

APP = "/Applications/Hermes Island.app/Contents/MacOS/HermesIsland"
AGENT = "dev.hermes-island.app.agent"
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


def installed_commit(plugin_dir: Path) -> Optional[str]:
    """The commit Hermes installed this plugin from, read from the installer's record beside it: the catalog's
    pinned sha, else the revision a git install checked out. None when Hermes did not install it."""
    plugin_dir = plugin_dir.resolve()
    try:
        rows = json.loads((plugin_dir.parent / ".install-metadata.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    record = rows.get(plugin_dir.name) if isinstance(rows, dict) else None
    if not isinstance(record, dict):
        return None
    catalog = record.get("catalog") if isinstance(record.get("catalog"), dict) else {}
    commit = str(catalog.get("sha") or record.get("revision") or "").lower()
    return commit if len(commit) == 40 and all(c in "0123456789abcdef" for c in commit) else None


def fetch_source(commit: str, cache: Path) -> tuple[Optional[Path], str]:
    """A checkout of the app's repository at exactly `commit`, cloned into `cache` once and reused after."""
    root = cache / commit
    git = ["/usr/bin/git", "-C", str(root)]

    def head() -> str:
        return subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True, text=True, check=False).stdout.strip()

    if (root / "scripts" / "build-app.sh").is_file() and head() == commit:
        return root, f"Using the source at {commit[:12]} in {root}."
    shutil.rmtree(root, ignore_errors=True)
    cache.mkdir(parents=True, exist_ok=True)
    # The full history, without file contents until checkout: build-app.sh numbers the build by its commit count.
    steps = [["/usr/bin/git", "clone", "-q", "--filter=blob:none", "--no-checkout", REPO, str(root)],
             git + ["-c", "advice.detachedHead=false", "checkout", "-q", "--detach", commit]]
    for step in steps:
        done = subprocess.run(step, capture_output=True, text=True, check=False, timeout=600)
        if done.returncode != 0:
            shutil.rmtree(root, ignore_errors=True)
            return None, f"Could not get {REPO} at {commit}: {done.stderr.strip()}"
    if head() != commit:
        shutil.rmtree(root, ignore_errors=True)
        return None, f"The checkout of {REPO} is not at {commit}."
    return root, f"Cloned {REPO} at {commit[:12]} into {root}."


def build_steps(root: Path) -> list[list[str]]:
    scripts = root / "scripts"
    return [[str(scripts / "fetch-deps.sh")], [str(scripts / "test.sh")], [str(scripts / "build-app.sh")]]


LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/"
              "lsregister")


def install(built: Path, target: Path) -> tuple[int, str]:
    """Puts a new build in place of the installed app and starts it again.

    macOS's login item record pins the build it was registered with, and launchd refuses a different one with a
    launch constraint error. Measured on macOS 26: the record takes the new build when that build is opened while
    the login item is on and hands over to it, and the login item then starts it after one more turn off and on
    with LaunchServices reading the bundle again in between."""
    binary = str(target / "Contents/MacOS/HermesIsland")

    def app(*arguments: str) -> str:
        return subprocess.run([binary, *arguments], capture_output=True, text=True, check=False, timeout=30).stdout

    def copies() -> list[int]:
        found = subprocess.run(["/usr/bin/pgrep", "-x", "HermesIsland"], capture_output=True, text=True, check=False)
        return [int(pid) for pid in found.stdout.split()]

    def launchd_runs_it() -> bool:
        job = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{AGENT}"], capture_output=True, text=True,
                             check=False)
        return any(line.strip().startswith("pid = ") for line in job.stdout.splitlines())

    def wait_until(check: Callable[[], bool], seconds: float) -> bool:
        for _ in range(int(seconds * 2)):
            if check():
                return True
            time.sleep(0.5)
        return check()

    def lsregister(*arguments: str) -> None:
        subprocess.run([LSREGISTER, *arguments, str(target)], capture_output=True, check=False, timeout=60)

    login = Path(binary).is_file() and "launch agent: enabled" in app("--login-status")
    if login:
        app("--open-at-login", "off")  # ends the copy launchd started
    # Assembled beside the old copy and renamed into place: writing over a running app's binary kills it.
    fresh, aside = target.with_name(".Hermes Island.new.app"), target.with_name(".Hermes Island.old.app")
    for leftover in (fresh, aside):
        shutil.rmtree(leftover, ignore_errors=True)
    if subprocess.run(["/usr/bin/ditto", str(built), str(fresh)], check=False).returncode != 0:
        return 1, f"Could not copy {built} to {fresh}."
    if target.exists():
        target.rename(aside)
    fresh.rename(target)
    shutil.rmtree(aside, ignore_errors=True)
    lsregister("-f", "-R")
    if not login:
        subprocess.run(["/usr/bin/open", str(target)], check=False, timeout=30)
        return 0, f"Installed {target}. Allow Accessibility and the microphone when macOS asks."
    app("--open-at-login", "on")
    for _ in range(3):
        subprocess.run(["/usr/bin/open", str(target)], check=False, timeout=30)
        time.sleep(5)
        stayed = copies()
        if not stayed:
            break  # it handed over to the login item, which is the step that matters
        for pid in stayed:  # the copy just opened, which ran by itself instead
            os.kill(pid, signal.SIGTERM)
        wait_until(lambda: not copies(), 5)
    app("--open-at-login", "off")
    lsregister("-u")
    time.sleep(2)
    lsregister("-f", "-R")
    time.sleep(2)
    app("--open-at-login", "on")
    if not wait_until(launchd_runs_it, 10):
        subprocess.run(["/usr/bin/open", str(target)], check=False, timeout=30)
        return 1, (f"Installed {target}, but the login item would not start it, so it was opened by hand. Turn "
                   "Open at Login off and on in its menu.")
    return 0, f"Installed {target} and started it. Allow Accessibility and the microphone when macOS asks."
