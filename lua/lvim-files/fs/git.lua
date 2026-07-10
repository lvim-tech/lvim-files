-- lvim-files.fs.git: asynchronous git status decorations. One `git status --porcelain=v2
-- --ignored -z` run per repository root (debounced per config.git.debounce), parsed into a
-- per-path status map plus an ignored set; directory badges are derived by propagating each
-- entry's status to its ancestors (the worst status wins). Both presentations read the same
-- maps; a completed refresh is broadcast to listeners so the views repaint.
--
---@module "lvim-files.fs.git"

local config = require("lvim-files.config")

local uv = vim.uv

local M = {}

---@class LvimFilesGitRoot
---@field status table<string, string>   absolute path → status name (files as reported)
---@field dirsev table<string, integer>  absolute dir path → propagated severity rank
---@field ignored table<string, boolean> absolute path → ignored (dirs cover their contents)
---@field timer uv.uv_timer_t            the per-root debounce timer
---@field running boolean                a status run is in flight
---@field queued boolean                 a refresh arrived while running — run again after

---@type table<string, LvimFilesGitRoot>  toplevel → state
local roots = {}
---@type table<string, string|false>  directory → its toplevel ("false" = not a repository)
local top_cache = {}
---@type table<string, fun(top: string|false)[]>  directory → callbacks awaiting toplevel resolution
local top_pending = {}
---@type table<integer, fun(top: string)>
local listeners = {}
---@type integer
local listener_seq = 0

-- Status name → propagation severity (a directory shows the WORST status underneath it).
---@type table<string, integer>
local SEVERITY = {
    untracked = 1,
    added = 2,
    renamed = 3,
    modified = 4,
    deleted = 5,
    conflict = 6,
}

-- Severity rank → status name (for directory badges).
---@type table<integer, string>
local SEV_NAME = {}
for name, rank in pairs(SEVERITY) do
    SEV_NAME[rank] = name
end

--- Whether git is usable at all (memoized).
---@type boolean|nil
local has_git = nil
---@return boolean
function M.available()
    if has_git == nil then
        has_git = vim.fn.executable("git") == 1
    end
    return has_git
end

--- Map a porcelain XY pair to a status name. Precedence: conflict > deleted > renamed >
--- added > modified — a staged-new-then-edited file still reads "added" (it IS new).
---@param x string
---@param y string
---@return string|nil
local function xy_status(x, y)
    if x == "U" or y == "U" then
        return "conflict"
    end
    if x == "D" or y == "D" then
        return "deleted"
    end
    if x == "R" or y == "R" then
        return "renamed"
    end
    if x == "A" then
        return "added"
    end
    if x == "M" or x == "T" or y == "M" or y == "T" then
        return "modified"
    end
    return nil
end

--- Parse `--porcelain=v2 --ignored -z` output into fresh status/ignored maps.
---@param top string
---@param out string
---@return table<string, string> status, table<string, boolean> ignored
local function parse(top, out)
    local status, ignored = {}, {}
    local function abs(rel)
        rel = rel:gsub("/+$", "")
        return top .. "/" .. rel
    end
    -- Tokens are NUL-separated; a rename record (`2 …`) is followed by ONE extra token (the
    -- original path), so iterate with an index rather than a plain gmatch loop.
    local tokens = {}
    for tok in out:gmatch("([^%z]+)") do
        tokens[#tokens + 1] = tok
    end
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        local kind = t:sub(1, 1)
        if kind == "1" then
            local xy, path = t:match("^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
            if xy and path then
                local s = xy_status(xy:sub(1, 1), xy:sub(2, 2))
                if s then
                    status[abs(path)] = s
                end
            end
        elseif kind == "2" then
            local xy, path = t:match("^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
            if xy and path then
                local s = xy_status(xy:sub(1, 1), xy:sub(2, 2)) or "renamed"
                status[abs(path)] = s
            end
            i = i + 1 -- skip the origPath token that follows a rename record
        elseif kind == "u" then
            local path = t:match("^u .. %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
            if path then
                status[abs(path)] = "conflict"
            end
        elseif kind == "?" then
            local path = t:match("^%? (.*)$")
            if path then
                status[abs(path)] = "untracked"
            end
        elseif kind == "!" then
            local path = t:match("^! (.*)$")
            if path then
                ignored[abs(path)] = true
            end
        end
        i = i + 1
    end
    return status, ignored
end

--- Propagate each file status up to the toplevel so directories badge with the worst
--- contained status. Ignored entries do not propagate (a repo full of ignored build output
--- should not paint its parents).
---@param top string
---@param status table<string, string>
---@return table<string, integer>
local function propagate(top, status)
    local dirsev = {}
    for path, name in pairs(status) do
        local sev = SEVERITY[name]
        if sev then
            local dir = vim.fs.dirname(path)
            while dir and #dir >= #top do
                if not dirsev[dir] or dirsev[dir] < sev then
                    dirsev[dir] = sev
                end
                if dir == top then
                    break
                end
                dir = vim.fs.dirname(dir)
            end
        end
    end
    return dirsev
end

--- Resolve the repository toplevel for a directory (async, memoized). `cb(top|false)`.
---@param dir string
---@param cb fun(top: string|false)
function M.toplevel(dir, cb)
    if not (config.git.enabled and M.available()) then
        cb(false)
        return
    end
    local cached = top_cache[dir]
    if cached ~= nil then
        cb(cached)
        return
    end
    if top_pending[dir] then
        top_pending[dir][#top_pending[dir] + 1] = cb
        return
    end
    top_pending[dir] = { cb }
    vim.system(
        { "git", "-C", dir, "rev-parse", "--show-toplevel" },
        { text = true },
        vim.schedule_wrap(function(res)
            local top = false
            if res.code == 0 and res.stdout then
                local line = res.stdout:gsub("%s+$", "")
                if line ~= "" then
                    top = line
                end
            end
            top_cache[dir] = top
            local cbs = top_pending[dir] or {}
            top_pending[dir] = nil
            for _, f in ipairs(cbs) do
                pcall(f, top)
            end
        end)
    )
end

--- Run the actual status command for a toplevel and publish the parsed maps.
---@param top string
local function run_status(top)
    local r = roots[top]
    if not r then
        return
    end
    if r.running then
        r.queued = true
        return
    end
    r.running = true
    vim.system(
        { "git", "-C", top, "status", "--porcelain=v2", "--ignored", "-z" },
        { text = true },
        vim.schedule_wrap(function(res)
            r.running = false
            if res.code == 0 then
                r.status, r.ignored = parse(top, res.stdout or "")
                r.dirsev = propagate(top, r.status)
                for _, fn in pairs(listeners) do
                    pcall(fn, top)
                end
            end
            if r.queued then
                r.queued = false
                run_status(top)
            end
        end)
    )
end

--- Request a (debounced) status refresh for the repository containing `path`. Creates the
--- root state on first sight. A path outside any repository is a no-op.
---@param path string
function M.refresh(path)
    if not (config.git.enabled and M.available()) then
        return
    end
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    M.toplevel(dir, function(top)
        if not top then
            return
        end
        local r = roots[top]
        if not r then
            local timer = uv.new_timer()
            if not timer then
                return
            end
            r = { status = {}, dirsev = {}, ignored = {}, timer = timer, running = false, queued = false }
            roots[top] = r
        end
        r.timer:stop()
        r.timer:start(
            math.max(0, config.git.debounce or 150),
            0,
            vim.schedule_wrap(function()
                run_status(top)
            end)
        )
    end)
end

--- The root state covering `path` (the longest matching toplevel), or nil.
---@param path string
---@return LvimFilesGitRoot|nil, string|nil
local function root_for(path)
    local best, best_top
    for top, r in pairs(roots) do
        if path == top or path:sub(1, #top + 1) == top .. "/" then
            if not best_top or #top > #best_top then
                best, best_top = r, top
            end
        end
    end
    return best, best_top
end

--- The git status name decorating `path`: its own reported status, else (directories) the
--- worst propagated status underneath, else "ignored" when covered by an ignored entry.
---@param path string
---@return string|nil
function M.status(path)
    local r = root_for(path)
    if not r then
        return nil
    end
    local own = r.status[path]
    if own then
        return own
    end
    local sev = r.dirsev[path]
    if sev then
        return SEV_NAME[sev]
    end
    if M.is_ignored(path) then
        return "ignored"
    end
    return nil
end

--- Whether `path` is git-ignored (directly, or via an ignored ancestor directory).
---@param path string
---@return boolean
function M.is_ignored(path)
    local r, top = root_for(path)
    if not r then
        return false
    end
    local p = path
    while p and #p >= #(top or "") do
        if r.ignored[p] then
            return true
        end
        if p == top then
            break
        end
        p = vim.fs.dirname(p)
    end
    return false
end

--- Subscribe to completed status refreshes (`fn(toplevel)`). Returns an unsubscribe.
---@param fn fun(top: string)
---@return fun()
function M.on_change(fn)
    listener_seq = listener_seq + 1
    local id = listener_seq
    listeners[id] = fn
    return function()
        listeners[id] = nil
    end
end

return M
