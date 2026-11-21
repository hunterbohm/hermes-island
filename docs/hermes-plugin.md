# Plan: Hermes Island as a Hermes plugin

Status: the plugin is built in `hermes-plugin/` and passes `hermes plugins validate` and `hermes plugins doctor --ci`. Nothing is submitted. Making the repo public and opening the catalog PR are the owner's to do.

## What Hermes already gives us

Talks need no plugin: the island starts `hermes acp` (locally or `ssh HOST hermes acp`) and speaks ACP. The plugin adds what Hermes can't do today: ring the island when a job finishes, and set the app up from Hermes.

## Shape

A general plugin (`plugin.yaml` + `register(ctx)`) in `hermes-plugin/` of this repo. The catalog entry points at it with `subdir: hermes-plugin` and a 40-character SHA pin, like `plugin-catalog/spotify.yaml`.

	hermes-plugin/
	  plugin.yaml        # manifest v2, capabilities declared exactly (catalog rule 6)
	  __init__.py        # register(ctx): one tool, one CLI command
	  island.py          # finds the app, builds the `call` command, parses its JSON status lines
	  skills/talk-island/SKILL.md   # how to answer in a spoken talk, when to offer a call back

What it registers:

1. **Tool `island_call_back`** (`about`, `result`, optional `ring_seconds`). Runs `HermesIsland call --about …` with the result on stdin and returns the final status (`delivered`, `declined`, `missed`, `busy`, `hung-up`, `failed`), its exit code and the next step, so the agent can text instead when the user is busy. On macOS it runs the app's binary directly. When Hermes runs on another machine, it runs it through the `transport` setting (`plugins.entries.hermes-island.settings.transport: "ssh -o BatchMode=yes my-mac"`).
2. **CLI `hermes island`**: `status` (where the island is, which agent it talks to, busy now, open at login, running), `build` (runs `scripts/fetch-deps.sh`, `scripts/test.sh` and `scripts/build-app.sh` from a source checkout, then offers to copy the app to /Applications), and `setup` (runs `HermesIsland agent --hermes [--host HOST]`, so the app writes its own settings). A catalog install is a sparse checkout of `hermes-plugin/` alone, so `build` takes `--source DIR` there.

No hooks, no middleware, no env vars, no core overrides.

## Catalog rules that shape it

- **No self-updating code (rule 3).** The plugin must not download a signed release of the app. `hermes island build` builds the app from the exact commit the catalog pinned, which keeps the SHA pin the only trust anchor. The standalone GitHub releases can keep their own download path.
- **Declared capabilities must match (rule 6).** `provides_tools: [island_call_back]`, `provides_hooks: []`, `requires_env: []`.
- **Install scanner (rule 7).** `subprocess` calls to `ssh` and the app binary will likely show as `caution`; keep the argument lists fixed, never `shell=True`, and quote the remote command with `shlex`.
- **Owner submission (rule 5).** The repo owner opens the catalog PR.
- **macOS only.** The tool returns a clear "no island on this machine" result elsewhere unless a transport is set. The manifest lists `platforms: [macos]` if the schema takes it.

## Before submitting

Done: its own icon; the bundle id `dev.hermes-island.app`, with a one-time settings copy from `com.hunterbohm.hermesisland`; personal names, hosts and handles out of code, tests and docs; the plugin, passing validate and doctor.

Left:

1. The owner makes the repo public, after one more look at the history.
2. A Developer ID signature and notarization for people who install a release instead of building. The self-signed certificate works only on the Mac that built it.
3. A short screen recording of a talk for the README and the catalog entry's `image`.
4. The catalog entry (`plugin-catalog/hermes-island.yaml`: `repo`, the 40-character `sha`, `subdir: hermes-plugin`, `platforms`), opened as a PR by the owner.
