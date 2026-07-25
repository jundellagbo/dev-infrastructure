<!-- infra-llm:start -->

## Step-by-step execution protocol (infra-llm)

Multi-step work is tracked as `- [ ]` / `- [x]` checkboxes **inside the plan file
itself**, under `infra-llm/plans/` and registered in `.active-plan`. There is no
separate progress file. The hooks that enforce this live in the infra checkout
and run through the `infra-llm` command, so nothing is vendored here.
`infra-llm --skill infra-llm-step` prints the full protocol.

**How to work.** A task with more than one step — or a prompt naming a plan file
— starts by turning **every** discrete item into its own `- [ ]` checkbox,
edited into the plan file in place (`infra-llm --plan <slug>` creates and
registers one for ad-hoc work). Then implement exactly **one** unchecked step per
turn, mark it `- [x]`, and stop: the Stop hook blocks the stop and hands you the
next step, so starting it early only makes the turn harder to review. Never batch
steps and never drop one silently — something unnecessary is marked
`- [x] … (skipped: reason)`, not deleted. When every box is checked run
`infra-llm --verify` and fix what it reports until it prints `VERIFY OK`. An
active plan with unchecked steps is resumed before anything new is started. The
stop hook gives up after 3 consecutive auto-continues with no progress; if you
hit that, say what is blocking you instead of spinning.

| Command | What you get |
| --- | --- |
| `infra-llm --plan <slug>` | create `infra-llm/plans/<slug>.md` and register it |
| `infra-llm --steps` | the next unchecked step the stop hook will demand |
| `infra-llm --verify` | this repo's checks, then the plan closes out |
| `infra-llm --status` · `--sessions` · `--skill <name>` | wiring and plan state · past sessions · a protocol skill |

**Writing plans and instructions.** Everything an agent re-reads later — a plan
file, this block, a skill, a brief — is short, direct and paragraph-first. Say
what to do and why it matters, then stop; padding is paid for on every future run
and buries the line that mattered. A plan step is one line naming a concrete
outcome, with detail underneath only where it isn't obvious, and prose around it
stays a couple of sentences. Explaining the reason beats stacking MUSTs. Write
plan files yourself and get on with the work — use the `skill-creator` skill only
for a **skill, instruction file or command**, whose frontmatter description
decides whether it ever triggers.

**Don't edit what infra-llm generates.** This block (everything between the
`infra-llm` markers) and any skill or hook it installed are copies: edits are
lost on the next refresh and never reach the other repos. Change the source in
the infra checkout and re-run `infra-llm --docs`; if that isn't yours to change,
say what needs changing instead of patching the copy.

**Git is the user's decision.** Never run a repository-mutating git command —
commit, push, merge, rebase, reset, checkout, branch or tag creation, stash,
history rewriting. Leave the work in the tree and say what changed. Read-only git
(`status`, `diff`, `log`, `show`, `blame`) is encouraged. A guard hook enforces
this; don't route around it with aliases or wrappers. Never put AI/LLM
attribution in a commit message, tag, release note or PR body.

Pull requests and code review are on-request commands you run yourself —
`infra-llm --pull-request`, `infra-llm --code-review`. Each prints its own brief
when you run it, so there is no copy of it here to drift out of date. Review is
on request, never a gate on finishing a task.

**Browser work.** Asked to open, inspect, screenshot or debug a page, drive the
Chrome the user already has open: the `chrome-devtools` MCP server is registered
with `--autoConnect` and attaches to their logged-in profile, so open a new tab
there. Never ask which browser or profile to use and never launch a second one.
Check which browser you got before reporting anything — with remote debugging off
the server silently attaches to a throwaway profile and every call still
succeeds, so a page list holding one `about:blank` and none of their tabs means
you are in that scratch profile. Stop there, say so, and give them the fix: open
`chrome://inspect/#remote-debugging` (Chrome 144+), enable remote debugging,
restart Chrome, then restart the agent session. `DevToolsActivePort` is left
behind when the toggle goes off, so its existence proves nothing, and
`--remote-debugging-port` is not a workaround — Chrome has ignored it on the
default user data dir since version 136.

**Codebase memory.** When the `codebase-memory-mcp` tools are available, use them
to find code — `search_code`, `search_graph`, `trace_path`, `get_code_snippet`
answer structural questions off an index instead of re-reading files. Index the
repo once (`index_repository`) and fall back to Grep/Glob when the tools aren't
there.

**Worktrees.** `infra-llm/` is untracked, so every worktree has its own active
plan and session history and parallel agents don't collide. Work only in the
worktree you were started in: never edit another worktree's plan files, and never
assume a plan you can't see here. `infra-llm --worktrees` lists them. Session
records for the last 10 sessions land in `infra-llm/sessions/<session-id>.md` —
read them to recover what an earlier session was asked to do.

<!-- infra-llm:end -->
