-- The one filesystem model both presentations share.
--
-- The property the rest of the plugin is built on is written into the module's first paragraph: a
-- rescan RECONCILES into the existing nodes, matched by name, so node ids stay STABLE across
-- refreshes -- the edit view's extmark ids and the panel's expanded set both key off that. If a
-- rescan handed back fresh nodes, every refresh would lose the expanded directories and point the
-- edit view's extmarks at nothing.
--
-- The scan is asynchronous, so each case drives it and waits for its callback.

local model = require("lvim-files.fs.model")

--- A directory tree built from a spec: a string value is a file's contents, a table is a
--- directory. Returns the absolute root path.
---@param spec table
---@return string root
local function tree(spec)
    local root = vim.fn.tempname()
    local function build(dir, t)
        vim.fn.mkdir(dir, "p")
        for name, value in pairs(t) do
            if type(value) == "table" then
                build(dir .. "/" .. name, value)
            else
                vim.fn.writefile({ value }, dir .. "/" .. name)
            end
        end
    end
    build(root, spec)
    return root
end

--- Load `node`'s children and wait for the scan.
---@param node table
---@param force? boolean
local function load(node, force)
    local done = false
    model.load(node, function()
        done = true
    end, force)
    vim.wait(3000, function()
        return done
    end)
    truthy(done, "the scan never called back")
end

--- The child names of a loaded node, in the order the model put them.
---@param node table
---@return string[]
local function names(node)
    local out = {}
    for i, ch in ipairs(node.children or {}) do
        out[i] = ch.name
    end
    return out
end

describe("lvim-files: paths")

it("a path is made absolute and loses its trailing slash", function()
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    eq(cwd, model.normalize("."))
    eq(cwd, model.normalize(""), "an empty path is the working directory")
    eq("/tmp", model.normalize("/tmp/"))
    eq("/tmp", model.normalize("/tmp///"))
end)

it("the filesystem root keeps its slash", function()
    eq("/", model.normalize("/"), "stripping this one would leave the empty string")
end)

it("joining never doubles or drops a separator", function()
    eq("/a/b", model.join("/a", "b"))
    eq("/a/b", model.join("/a/", "b"))
    eq("/b", model.join("/", "b"))
end)

describe("lvim-files: scanning a directory")

it("the children are the directory's entries", function()
    local root = model.root(tree({ b = "x", a = "y", sub = { inner = "z" } }))
    load(root)
    eq({ "sub", "a", "b" }, names(root))
    eq(true, root.loaded)
end)

it("directories come first, then names case-insensitively", function()
    local root = model.root(tree({
        ["Beta.txt"] = "x",
        ["alpha.txt"] = "x",
        ["Zeta"] = { k = "x" },
        ["apples"] = { k = "x" },
    }))
    load(root)
    eq({ "apples", "Zeta", "alpha.txt", "Beta.txt" }, names(root), "a file manager's order, not ASCII's")
end)

it("a name differing only in case still has a total order", function()
    local root = model.root(tree({ ["a.txt"] = "x", ["A.txt"] = "x" }))
    load(root)
    local got = names(root)
    eq(2, #got)
    eq("A.txt", got[1], "the tie is broken case-sensitively, so the order is stable across runs")
    eq("a.txt", got[2])
end)

it("an empty directory loads as empty, not as unloaded", function()
    local root = model.root(tree({}))
    load(root)
    eq({}, names(root))
    eq(true, root.loaded, "an empty listing is an answer")
end)

it("a directory that cannot be read still resolves", function()
    local root = model.root(vim.fn.tempname() .. "/never-created")
    load(root)
    eq({}, names(root))
    eq(true, root.loaded, "a missing directory is an empty one, not a hang")
end)

it("a file's executable bit is recorded", function()
    local dir = tree({ ["plain.txt"] = "x", ["run.sh"] = "#!/bin/sh" })
    vim.uv.fs_chmod(dir .. "/run.sh", tonumber("755", 8))
    local root = model.root(dir)
    load(root)
    for _, ch in ipairs(root.children) do
        if ch.name == "run.sh" then
            eq(true, ch.executable)
        elseif ch.name == "plain.txt" then
            truthy(not ch.executable, "a plain file is not executable")
        end
    end
end)

describe("lvim-files: symlinks")

it("a link to a directory presents as a directory", function()
    local dir = tree({ real = { k = "x" } })
    vim.uv.fs_symlink(dir .. "/real", dir .. "/link")
    local root = model.root(dir)
    load(root)

    local link
    for _, ch in ipairs(root.children) do
        if ch.name == "link" then
            link = ch
        end
    end
    truthy(link, "the link was not listed: " .. vim.inspect(names(root)))
    eq("link", link.type, "its own type stays a link")
    eq(true, link.link_dir)
    eq(true, model.is_dir(link), "but it presents as a directory, so it can be expanded")
end)

it("a broken link is marked and is not a directory", function()
    local dir = tree({ k = "x" })
    vim.uv.fs_symlink(dir .. "/does-not-exist", dir .. "/dangling")
    local root = model.root(dir)
    load(root)

    local link
    for _, ch in ipairs(root.children) do
        if ch.name == "dangling" then
            link = ch
        end
    end
    truthy(link)
    eq(true, link.broken_link)
    eq(false, model.is_dir(link))
end)

describe("lvim-files: a rescan keeps the ids")

it("a node that is still there keeps its id", function()
    local dir = tree({ a = "x", b = "x", sub = { inner = "x" } })
    local root = model.root(dir)
    load(root)

    local before = {}
    for _, ch in ipairs(root.children) do
        before[ch.name] = ch.id
    end

    load(root, true) -- force a rescan of an unchanged directory

    for _, ch in ipairs(root.children) do
        eq(before[ch.name], ch.id, ch.name .. " was given a new id by a rescan")
    end
end)

it("a new entry gets an id without disturbing the others", function()
    local dir = tree({ a = "x" })
    local root = model.root(dir)
    load(root)
    local id_a = root.children[1].id

    vim.fn.writefile({ "x" }, dir .. "/b")
    load(root, true)

    eq({ "a", "b" }, names(root))
    for _, ch in ipairs(root.children) do
        if ch.name == "a" then
            eq(id_a, ch.id, "an unrelated addition must not renumber what was there")
        end
    end
end)

it("a removed entry is gone and no longer resolvable by id", function()
    local dir = tree({ a = "x", b = "x" })
    local root = model.root(dir)
    load(root)
    local id_b
    for _, ch in ipairs(root.children) do
        if ch.name == "b" then
            id_b = ch.id
        end
    end
    truthy(id_b)
    truthy(model.node(id_b), "precondition: it resolves while it exists")

    vim.fn.delete(dir .. "/b")
    load(root, true)

    eq({ "a" }, names(root))
    eq(nil, model.node(id_b), "a dropped node must not linger in the registry")
end)

it("an expanded subdirectory survives its parent's rescan", function()
    local dir = tree({ sub = { inner = "x" } })
    local root = model.root(dir)
    load(root)
    local sub = root.children[1]
    load(sub)
    eq({ "inner" }, names(sub))
    local sub_id, inner_id = sub.id, sub.children[1].id

    load(root, true)

    eq(sub_id, root.children[1].id, "the expanded directory keeps its identity")
    eq({ "inner" }, names(root.children[1]), "and its loaded children")
    eq(inner_id, root.children[1].children[1].id)
end)

describe("lvim-files: finding a node by path")

it("a path inside the tree resolves to its node", function()
    local dir = tree({ sub = { deeper = { leaf = "x" } } })
    local root = model.root(dir)
    load(root)
    load(root.children[1])
    load(root.children[1].children[1])

    local found = model.find(root, dir .. "/sub/deeper/leaf")
    truthy(found, "the path was loaded, so it has a node")
    eq("leaf", found.name)
    eq(root, model.find(root, dir), "the root resolves to itself")
end)

it("a path outside the tree, or not loaded yet, resolves to nothing", function()
    local dir = tree({ sub = { leaf = "x" } })
    local root = model.root(dir)
    load(root)

    eq(nil, model.find(root, "/etc/passwd"), "outside the root entirely")
    eq(nil, model.find(root, dir .. "/sub/leaf"), "inside, but its directory has not been scanned")
    eq(nil, model.find(root, dir .. "/nope"))
end)

it("releasing a tree drops every id in it", function()
    local dir = tree({ sub = { leaf = "x" } })
    local root = model.root(dir)
    load(root)
    load(root.children[1])

    local ids = { root.id, root.children[1].id, root.children[1].children[1].id }
    for _, id in ipairs(ids) do
        truthy(model.node(id), "precondition: id " .. id .. " resolves")
    end

    model.release(root)
    for _, id in ipairs(ids) do
        eq(nil, model.node(id), "id " .. id .. " outlived its tree")
    end
end)
