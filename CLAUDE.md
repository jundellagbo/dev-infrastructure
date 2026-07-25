<!-- infra-llm:start -->

**Writing plans and instructions.** Everything an agent re-reads — a plan file,
this block, a skill, a brief — is short and paragraph-first: say what to do and
why, then stop; padding is paid on every run. A plan step is one line naming an
outcome, detail underneath only where it isn't obvious. Reasons beat stacked
MUSTs. Write plan files yourself; use `skill-creator` only for a skill,
instruction file or command, whose frontmatter description decides whether it
ever triggers.

**Don't edit what infra-llm generates.** This block (between the `infra-llm`
markers) and any skill or hook it installed are copies — edits are lost on the
next refresh and never reach the other repos. Change the source in the infra
checkout and re-run `infra-llm --docs`, or say what needs changing.

**Git is the user's decision.** Never run a repository-mutating git command —
commit, push, merge, rebase, reset, checkout, branch/tag creation, stash or
history rewriting. Leave the work in the tree and say what changed; read-only git
(`status`, `diff`, `log`, `show`, `blame`) is fine. A guard hook enforces this —
don't route around it. Never put AI/LLM attribution in a commit, tag, release
note or PR.

**Browser work.** To open, inspect, screenshot or debug a page, drive the Chrome
the user already has open: the `chrome-devtools` MCP server is registered with
`--autoConnect` on their logged-in profile — open a new tab there, never ask
which browser, never launch a second. Check which browser you got first: with
remote debugging off the server silently attaches to a throwaway profile, so a
page list of one `about:blank` and none of their tabs means you're in it — stop,
say so, and give the fix: open `chrome://inspect/#remote-debugging` (Chrome
144+), enable remote debugging, restart Chrome, restart the session.
`DevToolsActivePort` persists when the toggle goes off so proves nothing, and
`--remote-debugging-port` is ignored on the default user data dir since Chrome
136.

**Codebase memory.** When `codebase-memory-mcp` tools are available, use them to
find code — `search_code`, `search_graph`, `trace_path`, `get_code_snippet`
answer structural questions off an index. Index once (`index_repository`); fall
back to Grep/Glob otherwise.

**Worktrees.** `infra-llm/` is untracked, so each worktree has its own plan and
session history. Work only in the worktree you were started in — never edit
another's plan files or assume a plan you can't see. `infra-llm --worktrees`
lists them; session records land in `infra-llm/sessions/<id>.md`.

<!-- infra-llm:end -->
