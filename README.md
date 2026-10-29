# nvim-atlas

A Neovim-native sidebar for driving AI coding sessions (currently Claude
Code) across multiple repos and worktrees at once: see every live session
and the worktrees it has touched, review a worktree's diff, leave notes,
deliver them back into the session, check PR/CI status, and clean up
worktrees and branches once their work has landed.

Status: early MVP, built to validate the workflow before any thought of a
standalone (non-Neovim) tool.

## Usage

`<leader>ae` (`:AtlasToggle`) opens the sidebar: live Claude Code
sessions, the worktrees each has touched, PR/CI status and pending
notes. It refreshes itself while open.

In the sidebar:

| Key    | On a session row                         | On a worktree row                    |
|--------|------------------------------------------|--------------------------------------|
| `<CR>` | open the session's tmux pane (live, interactive) | review its diff (diffview)   |
| `s`    | send all pending notes into the session  |                                      |
| `X`    | clean up its finished worktrees          |                                      |
| `y`    |                                          | copy its pending notes               |
| `r`    | refresh now (including PR/CI)            | same                                 |
| `q`    | close the sidebar                        | same                                 |

While reviewing a diff, `<leader>aa` adds a note on the current line, or
on the selected lines in visual mode. Notes show inline in the diff.

In the session view: `i` to type into the session, `<C-\><C-n>` back to
normal mode, `q` to close it. It's a real tmux client on a temporary
grouped session, so it renders exactly like tmux; while you type there,
the shared tmux window resizes to fit the Neovim window.

Cleanup only removes linked worktrees whose PR is merged or whose branch
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
