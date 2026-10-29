local data = require("atlas.data")

describe("atlas.data bin_dir resolution", function()
  after_each(function()
    data.configure({}) -- reset to default (trust $PATH) between tests
  end)

  it("falls back to the bare command name when bin_dir is unset", function()
    assert.are.equal("claude-status", data._resolve("claude-status"))
  end)

  it("resolves to bin_dir/<cmd> when it's an executable there", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local script = dir .. "/claude-status"
    vim.fn.writefile({ "#!/usr/bin/env bash", "echo hi" }, script)
    vim.fn.system({ "chmod", "+x", script })

    data.configure({ bin_dir = dir })
    assert.are.equal(script, data._resolve("claude-status"))

    vim.fn.delete(dir, "rf")
  end)

  it("falls back to the bare command name when bin_dir doesn't have it", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    data.configure({ bin_dir = dir })
    assert.are.equal("claude-status", data._resolve("claude-status"))
    vim.fn.delete(dir, "rf")
  end)

  it("expands ~ in bin_dir", function()
    data.configure({ bin_dir = "~/.dotfiles/bin" })
    assert.are.equal(vim.fn.expand("~/.dotfiles/bin/git-review"), data._resolve("git-review"))
  end)
end)
