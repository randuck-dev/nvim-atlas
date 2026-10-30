# nvim-atlas

A Neovim-native sidebar for driving AI coding sessions (currently Claude
Code) across multiple repos and worktrees at once: see every live session
and the worktrees it has touched, review a worktree's diff, leave notes,
deliver them back into the session, check PR/CI status, and clean up
worktrees and branches once their work has landed.

Status: early MVP, built to validate the workflow before any thought of a
standalone (non-Neovim) tool.

## Usage

`<leader>ae` (`:AtlasToggle`) opens the sidebar: a tree of repos, the
live Claude Code sessions working in each, and the worktrees each
session changed, with PR/CI status and pending notes. Worktrees a
session only touched without changing are hidden. It refreshes itself
while open.

In the sidebar, the top bar shows the keys for the row under the cursor;
`?` shows the full list at the bottom.

| Key    | On a session row                         | On a worktree row                    |
|--------|------------------------------------------|--------------------------------------|
| `n`    | new worktree + Claude session in its repo (also on a repo row) |              |
| `<CR>` | open the session's tmux pane (live, interactive) | review its diff (unified)    |
| `v`    |                                          | review side by side (diffview) |
| `s`    | send all pending notes into the session  |                                      |
| `X`    | clean up its finished worktrees, including its own (closes the session) |    |
| `o`    |                                          | open its PR in the browser           |
| `y`    |                                          | copy its pending notes               |
| `r`    | refresh now (including PR/CI)            | same                                 |
| `q`    | close the sidebar                        | same                                 |
| `m`    | move it into a section (or a new one)    |                                      |
| `S`    | new section                              | same                                 |
| `←` `→` | on a section/repo header: collapse / expand (`⏎` also expands; `h`/`l` work too); inside a group, `←` collapses it | |
| `?`    | show/hide all keys                       | same                                 |

Sections are your own groupings ("to deploy", "observability", ...):
`S` makes one, `m` on a session moves it in (or out), and on a section
row `R` renames it and `d` deletes it (its sessions go back under their
repo). Sections show first, in the order you made them, each session
with its repo name; everything else stays grouped by repo. Saved in
Neovim's state folder, so they survive restarts.

The unified review shows everything the worktree changed since its merge
base (committed, uncommitted and untracked) in one buffer, GitHub style,
with old/new line numbers and syntax highlighting (from each file's
whole current/base version, like diffview), and a panel of changed files
on the left as a folder tree (status, +/- counts; `⏎` jumps to a file;
`←`/`→` fold folders; the file you're reading is highlighted). In the diff: `]c`/`[c` next/previous hunk, `]f`/`[f` next/
previous file, `⏎` opens the file at that line in a split, `r` reloads,
`q` closes.

While reviewing (unified or side by side), `<leader>aa` adds a note on the
current line, or on the selected lines in visual mode. Notes show as
diagnostics (hint severity, ✎ in the gutter) in a virtual line below the
line they're on; `]d`/`[d` and diagnostic lists include them. That display
applies to atlas's own diagnostic namespace only, not your LSP diagnostics.

In the session view: `i` to type into the session, `<C-\><C-n>` back to
normal mode, `q` to close it. It's a real tmux client on a temporary
grouped session, so it renders exactly like tmux; while you type there,
the shared tmux window resizes to fit the Neovim window.

A worktree with a PR starts with its status icon (Nerd Font Octicons):
merged (purple), approved (green check), open in review (green), changes
requested (red), draft (gray), closed (red); the PR number and CI result
follow the name. `?` lists what each icon means. Other fonts:
`setup({ pr_icons = { merged = "M", ... } })`.

`n` asks for a branch name, creates the worktree with worktrunk
(`wt switch -c`, falling back to `git worktree add`) and opens a tmux
window named after the branch running `claude -n <branch>-<6 hex>`, in
the background: the session is named after its branch plus a short
random suffix, and the sidebar shows that name right away.

A session whose folder was removed (e.g. with `wt remove` while Claude
kept running) shows as `(folder removed)`; `X` on it closes the leftover
session.

Cleanup also offers the session's own worktree (e.g. one made with
`n`); confirming closes that session's tmux pane first. It only removes linked worktrees whose PR is merged or whose branch
is already in its target, with no uncommitted or untracked changes. It
asks first, and uses `git worktree remove` / `git branch -d` (never
force). Remote branches are left alone.

## Options

```lua
require("atlas").setup({
  bin_dir = "~/.dotfiles/bin", -- where claude-status/git-review live, if not on Neovim's PATH
  poll_ms = 5000,              -- session state refresh while the sidebar is open
  pr_poll_ms = 30000,          -- PR/CI status refresh (gh, network)
})
```

## Depends on

- [`claude-status`](https://github.com/randuck-dev/dotfiles/blob/main/bin/claude-status)
  and [`git-review`](https://github.com/randuck-dev/dotfiles/blob/main/bin/git-review)
  on `$PATH` — session/worktree tracking and merge-base diffing. If
  Neovim's own launch environment doesn't have them on `$PATH` (common
  for GUI/terminal-launched Neovim, which doesn't always inherit an
  interactive shell's sourced `.zshrc`/`.bashrc`), pass `bin_dir` to
  `setup()` instead of trying to fix `$PATH` globally:
  `require("atlas").setup({ bin_dir = "~/.dotfiles/bin" })`.
- [`gh`](https://cli.github.com/) — PR/CI status.
- [`diffview.nvim`](https://github.com/sindrets/diffview.nvim) and
  [`toggleterm.nvim`](https://github.com/akinsho/toggleterm.nvim).

## Testing

```
scripts/test.sh
```

Runs the plenary.nvim suite under `tests/atlas/` (clones plenary into
`.deps/` on first run). Tests exercise the real external processes
(`git`, `gh`, `claude-status`, terminal buffers) rather than mocking them
— see individual test files for the fixtures used.

## License

MIT, see [LICENSE](LICENSE).
