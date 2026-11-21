# Plan: Hermes Island as a Hermes plugin

Status: plan only. Nothing here is built or submitted. Making the repo public and opening a catalog PR are the owner's to do.

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

1. **Tool `island_call_back`** (`about`, `result`, optional `ring_seconds`). Runs `HermesIsland call --about … --result-file …` and returns the final status (`delivered`, `declined`, `missed`, `busy`, `hung-up`, `failed`) and its exit code, so the agent can text instead when the user is busy. On macOS it runs the app's binary directly. When Hermes runs on another machine, it runs it through a transport set in config (`island.transport: "ssh -o BatchMode=yes my-mac"`), the way `call-me-back` does today.
2. **CLI `hermes island`**: `status` (app found, running, Accessibility and microphone state, which agent it talks to), `build` (runs `scripts/fetch-deps.sh`, `scripts/test.sh` and `scripts/build-app.sh` from the plugin's own checkout, then offers to copy the app to /Applications), and `setup` (writes the island's agent entry for this Hermes: `hermes acp` here, or `ssh HOST hermes acp`).

No hooks, no middleware, no env vars, no core overrides.

## Catalog rules that shape it

- **No self-updating code (rule 3).** The plugin must not download a signed release of the app. `hermes island build` builds the app from the exact commit the catalog pinned, which keeps the SHA pin the only trust anchor. The standalone GitHub releases can keep their own download path.
- **Declared capabilities must match (rule 6).** `provides_tools: [island_call_back]`, `provides_hooks: []`, `requires_env: []`.
- **Install scanner (rule 7).** `subprocess` calls to `ssh` and the app binary will likely show as `caution`; keep the argument lists fixed, never `shell=True`, and quote the remote command with `shlex`.
- **Owner submission (rule 5).** The repo owner opens the catalog PR.
- **macOS only.** The tool returns a clear "no island on this machine" result elsewhere unless a transport is set. The manifest lists `platforms: [macos]` if the schema takes it.

## Before submitting

1. The owner makes the repo public. Check the history for anything private first (it starts clean, from a fresh `git init`).
2. Replace the Lip Service icon and pick a bundle id that is not personal (`dev.hermes-island.app` or similar), with a settings migration from `com.hunterbohm.hermesisland`.
3. A Developer ID signature and notarization for people who install the release instead of building. The self-signed certificate works only on the Mac that built it.
4. Port `call-me-back`'s ring step to the plugin tool, then point `call-me-back` at it.
5. `hermes plugins validate hermes-plugin/` and `hermes plugins doctor` pass at the commit to pin.
6. A short screen recording of a talk for the catalog entry's `image`/docs.
