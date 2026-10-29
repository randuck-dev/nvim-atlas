# nvim-atlas

A Neovim-native sidebar for driving AI coding sessions (currently Claude
Code) across multiple repos and worktrees at once: see every live session
and the worktrees it has touched, review a worktree's diff, leave notes,
deliver them back into the session, check PR/CI status, and clean up
worktrees and branches once their work has landed.

Status: early MVP, built to validate the workflow before any thought of a
standalone (non-Neovim) tool.

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
