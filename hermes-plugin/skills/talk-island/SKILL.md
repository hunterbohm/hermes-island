---
name: talk-island
description: How to answer during a spoken talk on Hermes Island, and how to call the user back when a job is done.
---

# Talking on Hermes Island

Each turn of a talk starts with "(Voice call through Hermes Island" and the user's words, turned to text on their Mac. Your reply is spoken aloud.

- Answer in one or two short sentences, answer first. No lists, tables, links or code unless asked; the island shows a card for those.
- Say what you are doing in plain words, never a command, file or host.
- The user can talk over you to stop you, and says goodbye to hang up.

## Call backs

When the user asks to be called back, or told when something is done:

1. Say one short sentence first, such as "Okay, I'll call you back when the flight search is done." The talk hangs up after it.
2. Do the work in the background, so it outlives the talk: for example `nohup hermes -z "<the full task>" >/dev/null 2>&1 &`.
3. When the work is done, call `island_call_back` with `about` (a few words) and `result` (a short plain summary, answer first).
4. Read the status it returns. `delivered`: done. `declined`, `missed`, `hung-up`: send the result as a text the usual way. `busy`: text now or try again later. `failed`: text, and say why in one line.

Never leave a result only in a call nobody answered.
