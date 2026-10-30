local sections = require("atlas.sections")

describe("atlas.sections", function()
  local file

  before_each(function()
    file = vim.fn.tempname() .. "/sections.json"
    sections._set_path(file)
  end)

  after_each(function()
    sections._set_path(nil)
    vim.fn.delete(vim.fn.fnamemodify(file, ":h"), "rf")
  end)

  it("starts empty", function()
    assert.are.same({}, sections.list())
    assert.is_nil(sections.section_of("s1"))
  end)

  it("keeps sections in the order they were made, without duplicates", function()
    sections.add("to deploy")
    sections.add("observability")
    sections.add("to deploy")
    assert.are.same({ "to deploy", "observability" }, sections.list())
  end)

  it("rejects an empty name", function()
    local ok = sections.add("   ")
    assert.is_false(ok)
    assert.are.same({}, sections.list())
  end)

  it("moves a session into a section, creating it if needed, and out again", function()
    sections.assign("s1", "to deploy")
    assert.are.same({ "to deploy" }, sections.list())
    assert.are.equal("to deploy", sections.section_of("s1"))

    sections.assign("s1", nil)
    assert.is_nil(sections.section_of("s1"))
    assert.are.same({ "to deploy" }, sections.list(), "the section stays")
  end)

  it("renames a section and keeps its sessions in it", function()
    sections.assign("s1", "obs")
    assert.is_true(sections.rename("obs", "observability"))
    assert.are.same({ "observability" }, sections.list())
    assert.are.equal("observability", sections.section_of("s1"))
  end)

  it("won't rename onto an existing section", function()
    sections.add("a")
    sections.add("b")
    local ok, err = sections.rename("a", "b")
    assert.is_false(ok)
    assert.truthy(err:find("already exists", 1, true))
  end)

  it("deleting a section takes its sessions out of it", function()
    sections.assign("s1", "to deploy")
    sections.assign("s2", "observability")
    sections.remove("to deploy")
    assert.are.same({ "observability" }, sections.list())
    assert.is_nil(sections.section_of("s1"))
    assert.are.equal("observability", sections.section_of("s2"))
  end)

  it("persists across loads", function()
    sections.assign("s1", "to deploy")
    local raw = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
    assert.are.same({ "to deploy" }, raw.sections)
    assert.are.equal("to deploy", raw.assign.s1)
  end)

  it("remembers collapsed groups, and carries them through rename/delete", function()
    sections.add("obs")
    sections.set_collapsed("section:obs", true)
    sections.set_collapsed("repo:/x/y", true)
    assert.is_true(sections.is_collapsed("section:obs"))
    assert.is_true(sections.is_collapsed("repo:/x/y"))

    sections.rename("obs", "observability")
    assert.is_false(sections.is_collapsed("section:obs"))
    assert.is_true(sections.is_collapsed("section:observability"))

    sections.remove("observability")
    assert.is_false(sections.is_collapsed("section:observability"))

    sections.set_collapsed("repo:/x/y", false)
    assert.is_false(sections.is_collapsed("repo:/x/y"))
  end)
end)
