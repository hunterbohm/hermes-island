"""hermes-island: ring Hermes Island when a job is done, and set the app up from Hermes.

Talks themselves need no plugin: the island starts `hermes acp` and speaks ACP. This adds the `island_call_back`
tool and `hermes island status|build|setup`.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from pathlib import Path
from typing import Any

from . import island

logger = logging.getLogger(__name__)

CALL_BACK_SCHEMA = {
    "name": "island_call_back",
    "description": (
        "Call the user back on Hermes Island, the voice island on their Mac, when a job they asked about is done. "
        "The island rings; when they answer, a spoken talk starts in which you say the result. Waits until the call "
        "ends and returns its status: delivered (said), declined, missed or hung-up (text them the result instead), "
        "busy (in a meeting, a Focus or a locked screen: text now or try later), or failed. Use it only when the user "
        "asked to be called back or told when something is done."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "about": {"type": "string", "description": "What the call is about, in a few words: 'the flight search'."},
            "result": {"type": "string", "description": "What the job found, as plain text, answer first. Up to 20,000 characters."},
            "ring_seconds": {"type": "integer", "description": "How long the island rings before the call counts as missed. 5 to 120, default 30."},
        },
        "required": ["about", "result"],
    },
}


def register(ctx) -> None:
    def current() -> island.Island:
        return island.Island.from_settings(lambda key: ctx.get_config(key, default=""))

    def call_back(args: dict[str, Any], **_kwargs) -> str:
        try:
            outcome = island.call_back(current(), str(args.get("about") or ""), str(args.get("result") or ""),
                                       args.get("ring_seconds"))
        except Exception as error:  # a tool returns its error instead of raising
            logger.exception("island_call_back failed")
            outcome = {"status": "failed", "detail": str(error), "exit_code": 5, "next": island.NEXT_STEP[5]}
        return json.dumps(outcome, ensure_ascii=False)

    def setup_cli(parser) -> None:
        commands = parser.add_subparsers(dest="island_command")
        commands.add_parser("status", help="Show where the island is, who talks go to, and whether it runs")
        build = commands.add_parser("build", help="Build Hermes Island from source and offer to install it")
        build.add_argument("--source", help="A checkout of the app's repository (default: the one this plugin is in)")
        build.add_argument("--install", action="store_true", help="Copy the built app to /Applications without asking")
        setup = commands.add_parser("setup", help="Point the island's talks at this Hermes")
        setup.add_argument("--host", help="Run `hermes acp` over ssh on HOST instead of on the island's Mac")
        parser.set_defaults(func=command)

    def command(args) -> int:
        which = getattr(args, "island_command", None)
        if which == "status":
            for label, state in island.status(current()):
                print(f"{label:>14}  {state}")
            return 0
        if which == "setup":
            code, out = island.setup(current(), getattr(args, "host", None))
            print(out)
            return code
        if which == "build":
            return build(getattr(args, "source", None), getattr(args, "install", False))
        print("usage: hermes island status|build|setup")
        return 2

    ctx.register_tool(name="island_call_back", toolset="hermes_island", schema=CALL_BACK_SCHEMA, handler=call_back,
                      emoji="📞")
    ctx.register_cli_command(name="island", help="Hermes Island: status, build, setup", setup_fn=setup_cli,
                             handler_fn=command,
                             description="Ring Hermes Island when a job is done, and set the app up from Hermes.")
    skills = Path(__file__).parent / "skills"
    for child in sorted(skills.iterdir()) if skills.is_dir() else []:
        if (child / "SKILL.md").is_file():
            ctx.register_skill(child.name, child / "SKILL.md")


def build(source: str | None, install: bool) -> int:
    """Builds the app from a source checkout. The plugin never downloads code: with no checkout it says how to get
    the one that matches this plugin."""
    root = Path(source).expanduser() if source else island.source_checkout(Path(__file__).parent)
    if root is None or not (root / "scripts" / "build-app.sh").is_file():
        print("No source checkout of Hermes Island found. Clone it, check out the commit this plugin came from, then:")
        print(f"  git clone {island.REPO} && hermes island build --source hermes-island")
        return 1
    for step in island.build_steps(root):
        print("$ " + " ".join(step))
        if subprocess.run(step, cwd=root, check=False).returncode != 0:
            return 1
    built = root / "dist" / "Hermes Island.app"
    if not install:
        answer = input(f"Copy {built} to /Applications? [y/N] ").strip().lower()
        install = answer in ("y", "yes")
    if install:
        # Assembled beside the old copy and renamed into place: writing over a running app's binary kills it.
        target = Path("/Applications/Hermes Island.app")
        fresh, aside = target.with_name(".Hermes Island.new.app"), target.with_name(".Hermes Island.old.app")
        for leftover in (fresh, aside):
            shutil.rmtree(leftover, ignore_errors=True)
        done = subprocess.run(["/usr/bin/ditto", str(built), str(fresh)], check=False)
        if done.returncode != 0:
            return done.returncode
        if target.exists():
            target.rename(aside)
        fresh.rename(target)
        shutil.rmtree(aside, ignore_errors=True)
        print(f"Installed {target}. Open it, then allow Accessibility and the microphone when asked.")
    return 0
