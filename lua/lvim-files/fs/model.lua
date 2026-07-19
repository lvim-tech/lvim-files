-- lvim-files.fs.model: the ONE filesystem tree model shared by both presentations (the tree
-- panel and the edit buffer). Directories are scanned asynchronously (vim.uv.fs_scandir) and
-- loaded lazily per directory; a rescan RECONCILES into the existing nodes (matched by name)
-- so node ids stay stable across refreshes — the edit view's extmark ids and the panel's
-- expanded set both key off that stability. Open directories are watched with uv.fs_event
-- (debounced) and every change is broadcast to the registered listeners.
--
---@module "lvim-files.fs.model"

local uv = vim.uv

local M = {}

---@class LvimFilesNode
---@field id integer            stable identity (preserved across rescans, keyed by parent+name)
---@field path string           absolute path, no trailing slash
---@field name string           basename
---@field type string           "file" | "directory" | "link" | any other uv type
---@field link_dir? boolean     symlink resolving to a directory
---@field broken_link? boolean  symlink whose target does not exist
---@field executable? boolean   regular file with the execute bit for this process
---@field parent? LvimFilesNode
---@field children? LvimFilesNode[]  nil until the first scan completes
---@field loaded? boolean       children reflect a completed scan
---@field _loading? boolean     a view's in-flight-load marker (set/cleared by the views)

---@type integer  monotonically increasing node id
local next_id = 1
---@type table<integer, LvimFilesNode>
local by_id = {}
---@type table<string, { event: uv.uv_fs_event_t, timer: uv.uv_timer_t, nodes: table<integer, LvimFilesNode>, count: integer }>
local watchers = {}
---@type table<integer, fun(node: LvimFilesNode)>
local listeners = {}
---@type integer
local listener_seq = 0

-- The debounce for a watcher burst (a `git checkout` touches many entries at once); short —
-- the per-root git refresh has its own, longer debounce.
local WATCH_DEBOUNCE_MS = 80

--- Normalize any user-supplied path to an absolute, slash-normalized path without a trailing
--- slash (except the filesystem root itself).
---@param path string
---@return string
function M.normalize(path)
    local p = vim.fs.normalize(vim.fn.fnamemodify(path == "" and "." or path, ":p"))
    if #p > 1 then
        p = p:gsub("/+$", "")
    end
    return p
end

--- Join a directory path and an entry name.
---@param dir string
---@param name string
---@return string
function M.join(dir, name)
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

--- Allocate a fresh node.
---@param path string
---@param name string
---@param typ string
---@param parent? LvimFilesNode
---@return LvimFilesNode
local function new_node(path, name, typ, parent)
    local node = { id = next_id, path = path, name = name, type = typ, parent = parent }
    by_id[next_id] = node
    next_id = next_id + 1
    return node
end

--- Look a node up by its stable id.
---@param id integer
---@return LvimFilesNode|nil
function M.node(id)
    return by_id[id]
end

--- Create a fresh ROOT node for a directory. Roots are intentionally NOT deduplicated: each
--- view (a panel root, an edit-view directory) owns its own subtree so their lifetimes never
--- entangle; id stability only matters WITHIN a view's tree.
---@param path string
---@return LvimFilesNode
function M.root(path)
    path = M.normalize(path)
    return new_node(path, vim.fn.fnamemodify(path, ":t"), "directory")
end

--- Whether a node presents as a directory (a real one, or a symlink to one).
---@param node LvimFilesNode
---@return boolean
function M.is_dir(node)
    return node.type == "directory" or (node.type == "link" and node.link_dir == true)
end

--- Drop a node's subtree from the id registry (and any watchers on it). The node object itself
--- stays valid for anyone still holding it, but it is no longer resolvable by id.
---@param node LvimFilesNode
local function drop(node)
    M.unwatch(node)
    by_id[node.id] = nil
    for _, ch in ipairs(node.children or {}) do
        drop(ch)
    end
end

--- Release a whole subtree (drop ids + watchers). Called by a view when it discards its root.
---@param node LvimFilesNode
function M.release(node)
    drop(node)
end

---@class LvimFilesScanEntry
---@field name string
---@field type string
---@field link_dir? boolean
---@field broken_link? boolean
---@field executable? boolean

--- Asynchronously list a directory: names + types from fs_scandir, then a stat fan-in that
--- resolves symlink targets and the execute bit. `cb(entries|nil)` fires on the uv loop (the
--- caller schedules before touching vim state).
---@param path string
---@param cb fun(entries: LvimFilesScanEntry[]|nil)
local function scan_dir(path, cb)
    uv.fs_scandir(path, function(err, handle)
        if err or not handle then
            cb(nil)
            return
        end
        ---@type LvimFilesScanEntry[]
        local entries = {}
        while true do
            local name, typ = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            entries[#entries + 1] = { name = name, type = typ or "file" }
        end
        -- Stat fan-in: symlinks need a follow-stat to know what they point at; regular files an
        -- access check for the execute marker. `pending` counts the in-flight stats; the scan
        -- resolves once the listing AND every stat are done.
        local pending, listed = 0, false
        local function finish()
            if listed and pending == 0 then
                cb(entries)
            end
        end
        for _, e in ipairs(entries) do
            local p = M.join(path, e.name)
            if e.type == "link" then
                pending = pending + 1
                uv.fs_stat(p, function(serr, st)
                    if serr or not st then
                        e.broken_link = true
                    else
                        e.link_dir = st.type == "directory"
                    end
                    pending = pending - 1
                    finish()
                end)
            elseif e.type == "file" then
                pending = pending + 1
                uv.fs_access(p, "X", function(_, ok)
                    e.executable = ok == true
                    pending = pending - 1
                    finish()
                end)
            end
        end
        listed = true
        finish()
    end)
end

--- Sort entries the file-manager way: directory-likes first, then case-insensitive by name
--- (ties broken case-sensitively so the order is total and stable).
---@param entries LvimFilesScanEntry[]
local function sort_entries(entries)
    local function dirlike(e)
        return e.type == "directory" or (e.type == "link" and e.link_dir == true)
    end
    table.sort(entries, function(a, b)
        local da, db = dirlike(a), dirlike(b)
        if da ~= db then
            return da
        end
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then
            return la < lb
        end
        return a.name < b.name
    end)
end

--- Merge a fresh scan into `node.children` IN PLACE, preserving existing child nodes (matched
--- by name + type) so their ids, loaded subtrees and watchers survive a refresh. Vanished
--- children are dropped from the registry.
---@param node LvimFilesNode
---@param entries LvimFilesScanEntry[]
local function reconcile(node, entries)
    sort_entries(entries)
    ---@type table<string, LvimFilesNode>
    local old = {}
    for _, ch in ipairs(node.children or {}) do
        old[ch.name] = ch
    end
    local children = {}
    for _, e in ipairs(entries) do
        local ch = old[e.name]
        if ch and ch.type == e.type then
            old[e.name] = nil
        else
            ch = new_node(M.join(node.path, e.name), e.name, e.type, node)
        end
        ch.link_dir = e.link_dir
        ch.broken_link = e.broken_link
        ch.executable = e.executable
        children[#children + 1] = ch
    end
    for _, gone in pairs(old) do
        drop(gone)
    end
    node.children = children
    node.loaded = true
end

--- Load (or, with `force`, rescan) a directory node's children. `cb(node)` runs on the main
--- loop after the reconcile. A non-directory or unreadable path completes with no children.
---@param node LvimFilesNode
---@param cb? fun(node: LvimFilesNode)
---@param force? boolean
function M.load(node, cb, force)
    if node.loaded and not force then
        if cb then
            cb(node)
        end
        return
    end
    scan_dir(node.path, function(entries)
        vim.schedule(function()
            if entries then
                reconcile(node, entries)
            else
                node.children = node.children or {}
                node.loaded = true
            end
            if cb then
                cb(node)
            end
        end)
    end)
end

--- Notify every listener that `node`'s listing changed.
---@param node LvimFilesNode
local function emit(node)
    for _, fn in pairs(listeners) do
        pcall(fn, node)
    end
end

--- Subscribe to model changes (a watched directory was rescanned). Returns an unsubscribe.
---@param fn fun(node: LvimFilesNode)
---@return fun()
function M.on_change(fn)
    listener_seq = listener_seq + 1
    local id = listener_seq
    listeners[id] = fn
    return function()
        listeners[id] = nil
    end
end

--- Watch a directory node with uv.fs_event (refcounted per path). Events are debounced, then
--- the node is rescanned and the change broadcast via |M.on_change| listeners.
---@param node LvimFilesNode
function M.watch(node)
    if not M.is_dir(node) then
        return
    end
    local w = watchers[node.path]
    if w then
        -- A path can be watched by MORE THAN ONE node (two views over the same directory). Keep the
        -- whole SET of registrant nodes, keyed by id, not just the first — see the rescan note below.
        if not w.nodes[node.id] then
            w.nodes[node.id] = node
            w.count = w.count + 1
        end
        return
    end
    local event = uv.new_fs_event()
    local timer = uv.new_timer()
    if not (event and timer) then
        return
    end
    w = { event = event, timer = timer, nodes = { [node.id] = node }, count = 1 }
    watchers[node.path] = w
    event:start(node.path, {}, function()
        -- Coalesce a burst of events into one rescan; the timer callback hops to the main loop.
        timer:stop()
        timer:start(
            WATCH_DEBOUNCE_MS,
            0,
            vim.schedule_wrap(function()
                if watchers[node.path] ~= w then
                    return
                end
                -- Rescan every STILL-VALID registered node. Storing a single node would silently stop
                -- rescans for a surviving reference once that one node's subtree was released (its id
                -- gone from by_id) — re-resolving per event keeps every live view on the path refreshed.
                for id, n in pairs(w.nodes) do
                    if by_id[id] then
                        M.load(n, emit, true)
                    end
                end
            end)
        )
    end)
end

--- Release one watch reference on a directory node; the fs_event closes on the last release.
---@param node LvimFilesNode
function M.unwatch(node)
    local w = watchers[node.path]
    if not w then
        return
    end
    if w.nodes[node.id] then
        w.nodes[node.id] = nil
        w.count = w.count - 1
    end
    if w.count > 0 then
        return
    end
    watchers[node.path] = nil
    w.event:stop()
    if not w.event:is_closing() then
        w.event:close()
    end
    w.timer:stop()
    if not w.timer:is_closing() then
        w.timer:close()
    end
end

--- Find the loaded node for an absolute path under `root` (nil when the path is outside the
--- root or its branch is not loaded yet).
---@param root LvimFilesNode
---@param path string
---@return LvimFilesNode|nil
function M.find(root, path)
    path = M.normalize(path)
    if path == root.path then
        return root
    end
    local prefix = root.path == "/" and "/" or (root.path .. "/")
    if path:sub(1, #prefix) ~= prefix then
        return nil
    end
    local node = root
    for comp in path:sub(#prefix + 1):gmatch("[^/]+") do
        local found
        for _, ch in ipairs(node.children or {}) do
            if ch.name == comp then
                found = ch
                break
            end
        end
        if not found then
            return nil
        end
        node = found
    end
    return node
end

return M
