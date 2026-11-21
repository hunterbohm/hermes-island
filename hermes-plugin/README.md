# hermes-island plugin

Rings [Hermes Island](../README.md) when a job is done, and sets the app up from Hermes. Talks need no plugin: the island starts `hermes acp` itself.

- **Tool `island_call_back`** (`about`, `result`, optional `ring_seconds`). The island rings; when you answer, the agent says the result. It returns `delivered`, `declined`, `missed`, `hung-up`, `busy` or `failed`, so the agent can text you instead.
- **`hermes island status`** shows where the island is, who its talks go to, whether you are busy, and whether it runs.
- **`hermes island setup [--host HOST]`** points the island's talks at Hermes: `hermes acp` on the Mac, or over ssh on HOST.
- **`hermes island build [--source DIR] [--install]`** builds the app from a source checkout and offers to copy it to /Applications. The plugin downloads nothing.
- Skill `hermes-island:talk-island`: how to answer in a spoken talk, and the call back steps.

When Hermes runs on another machine, set the transport, a command that takes the remote command last:

	hermes config set plugins.entries.hermes-island.settings.transport "ssh -o BatchMode=yes my-mac"

Tests: `python3 -m unittest discover -s hermes-plugin/tests`. Catalog checks: `hermes plugins validate hermes-plugin` and `hermes plugins doctor hermes-plugin --ci`.
