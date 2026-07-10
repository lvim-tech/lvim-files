-- lvim-files.fs.diff: turn edited edit-view buffers into an ORDERED list of fs operations.
-- Pure data-in / data-out (no windows, no fs access) so the whole matrix is headless-testable.
--
-- Per directory view, each line's identity is its extmark-carried node id:
--   id present, text changed        → rename (within the directory)
--   line without an id              → create (trailing "/" = directory)
--   id missing from the buffer      → delete
-- Then the per-dir results are RECONCILED across every visited directory:
--   · a create whose RAW line text matches a recorded yank (`dd`/`yy` in the session) becomes
--     a MOVE when the yanked entry's line was deleted, else a COPY (duplicate-line copy);
--   · a create + a delete of the same basename pair into a MOVE (same dir = a pure reorder,
--     net no-op) — this is what makes `dd` … `p` across directories a move even though an
--     extmark cannot travel through a text register;
--   · renames/moves are topologically ordered on target-vs-source collisions, and a swap
--     CYCLE (a→b while b→a) is broken with a temporary-name hop;
--   · order: create dirs → copies → renames/moves → create files → deletes (deletes last, so
--     a mistaken pairing can never destroy data before everything else landed).
-- A remaining target collision is kept in the list with a `note` — the confirm panel shows
-- it and the apply step skips it (the ops engine refuses overwrites regardless).
--
---@module "lvim-files.fs.diff"

local M = {}

---@class LvimFilesEditView
---@field dir string                     absolute directory the view renders
---@field lines string[]                 the (pending) buffer text of that view
---@field ids table<integer, integer>    line number → node id (lines without a mark are absent)
---@field base table<integer, { name: string, type: string }>  node id → identity as rendered

---@class LvimFilesOp
---@field kind string    "create" | "rename" | "move" | "copy" | "delete"
---@field from? string   source path (rename/move/copy/delete)
---@field to? string     target path (create/rename/move/copy)
---@field dir? boolean   create: the target is a directory
---@field note? string   a conflict note — the op is SHOWN but skipped on apply

--- Join a directory and a (possibly nested) entry name.
---@param dir string
---@param name string
---@return string
local function join(dir, name)
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

--- Parse one edit-view line into an entry name. Strips the rendered icon — the FIRST UTF-8
--- character when it is multibyte and followed by whitespace (filenames practically never
--- start with a glyph-plus-space; a typed-in plain name passes through untouched) — and a
--- trailing "/" (which marks a CREATE as a directory).
---@param line string
---@return string|nil name, boolean is_dir, string raw   raw = the trimmed line (yank identity)
function M.parse_line(line)
    local raw = vim.trim(line or "")
    if raw == "" then
        return nil, false, raw
    end
    local name = raw
    local lead = name:byte(1)
    if lead and lead >= 0xC2 then
        local ch = name:match("^[\194-\244][\128-\191]*")
        if ch then
            local rest = name:sub(#ch + 1)
            local stripped = rest:match("^%s+(.*)$")
            if stripped and stripped ~= "" then
                name = stripped
            end
        end
    end
    local is_dir = false
    if name:sub(-1) == "/" then
        is_dir = true
        name = name:gsub("/+$", "")
    end
    if name == "" then
        return nil, false, raw
    end
    return name, is_dir, raw
end

---@class LvimFilesDelete
---@field path string
---@field name string
---@field type string
---@field consumed? boolean

--- Order the rename/move set so no op lands on a path another pending op still occupies.
--- A delete freeing a target is emitted just before the op that needs it; a pure CYCLE
--- (swap) is broken by hopping the first blocked op through a temporary name.
---@param rens LvimFilesOp[]
---@param dels_by_path table<string, LvimFilesDelete>
---@return LvimFilesOp[]
local function order_renames(rens, dels_by_path)
    local ordered = {}
    local pending = {}
    for _, op in ipairs(rens) do
        pending[#pending + 1] = op
    end
    while #pending > 0 do
        local progressed = false
        for i, op in ipairs(pending) do
            local blocked = false
            for j, other in ipairs(pending) do
                if j ~= i and other.from == op.to then
                    blocked = true
                    break
                end
            end
            if not blocked then
                local d = dels_by_path[op.to or ""]
                if d and not d.consumed then
                    -- The target is being deleted in the same sync — free it first.
                    d.consumed = true
                    ordered[#ordered + 1] = { kind = "delete", from = d.path }
                end
                ordered[#ordered + 1] = op
                table.remove(pending, i)
                progressed = true
                break
            end
        end
        if not progressed then
            -- Every pending op targets another pending op's source: a swap cycle. Hop the
            -- first through a temp name; it re-enters the pool and unblocks the rest.
            local op = pending[1]
            local tmp = op.to .. ".lvim-files-tmp"
            local n = 0
            while dels_by_path[tmp] do
                n = n + 1
                tmp = op.to .. ".lvim-files-tmp" .. n
            end
            ordered[#ordered + 1] = { kind = op.kind, from = op.from, to = tmp }
            op.from = tmp
        end
    end
    return ordered
end

--- Compute the ordered op list for a set of (pending) directory views.
---@param views LvimFilesEditView[]
---@param yanks? table<string, { path: string, dir: boolean }>  raw line text → yank source
---@return LvimFilesOp[]
function M.compute(views, yanks)
    yanks = yanks or {}
    ---@type LvimFilesOp[]
    local rens = {}
    ---@type { dir: string, name: string, is_dir: boolean, raw: string }[]
    local creates = {}
    ---@type LvimFilesDelete[]
    local dels = {}

    for _, view in ipairs(views) do
        local seen = {}
        for li, line in ipairs(view.lines or {}) do
            local id = view.ids and view.ids[li]
            local name, is_dir, raw = M.parse_line(line)
            if name then
                local b = id and view.base[id] or nil
                if b and not seen[id] then
                    seen[id] = true
                    if name ~= b.name then
                        rens[#rens + 1] = { kind = "rename", from = join(view.dir, b.name), to = join(view.dir, name) }
                    end
                else
                    -- No identity (or a second line claiming one — a join artefact): a create.
                    creates[#creates + 1] = { dir = view.dir, name = name, is_dir = is_dir, raw = raw }
                end
            end
        end
        for id, b in pairs(view.base or {}) do
            if not seen[id] then
                dels[#dels + 1] = { path = join(view.dir, b.name), name = b.name, type = b.type }
            end
        end
    end
    table.sort(dels, function(a, b)
        return a.path < b.path
    end)

    ---@type table<string, LvimFilesDelete>
    local dels_by_path = {}
    for _, d in ipairs(dels) do
        dels_by_path[d.path] = d
    end

    -- Reconcile creates into moves / copies / plain creates.
    ---@type LvimFilesOp[]
    local moves, copies, create_ops = {}, {}, {}
    for _, c in ipairs(creates) do
        local target = join(c.dir, c.name)
        local handled = false
        local y = yanks[c.raw]
        if y then
            local d = dels_by_path[y.path]
            if d and not d.consumed then
                d.consumed = true
                if y.path ~= target then
                    moves[#moves + 1] = { kind = "move", from = y.path, to = target }
                end
                handled = true -- y.path == target: cut + pasted back in place — a no-op
            elseif y.path ~= target then
                copies[#copies + 1] = { kind = "copy", from = y.path, to = target }
                handled = true
            else
                -- Duplicated in place without a new name: nothing valid to do; surface it.
                copies[#copies + 1] = { kind = "copy", from = y.path, to = target, note = "target exists" }
                handled = true
            end
        end
        if not handled then
            -- Same-name pairing: same dir first (a pure reorder cancels out), then cross-dir.
            local same = dels_by_path[target]
            if same and not same.consumed then
                same.consumed = true -- delete + re-create of the same entry = keep it
            else
                local found
                for _, d in ipairs(dels) do
                    if not d.consumed and d.name == c.name then
                        found = d
                        break
                    end
                end
                if found then
                    found.consumed = true
                    moves[#moves + 1] = { kind = "move", from = found.path, to = target }
                else
                    create_ops[#create_ops + 1] = { kind = "create", to = target, dir = c.is_dir }
                end
            end
        end
    end

    -- Assemble: create dirs → copies → renames/moves (ordered) → create files → deletes.
    ---@type LvimFilesOp[]
    local ops = {}
    for _, op in ipairs(create_ops) do
        if op.dir then
            ops[#ops + 1] = op
        end
    end
    for _, op in ipairs(copies) do
        ops[#ops + 1] = op
    end
    local ren_all = {}
    for _, op in ipairs(rens) do
        ren_all[#ren_all + 1] = op
    end
    for _, op in ipairs(moves) do
        ren_all[#ren_all + 1] = op
    end
    for _, op in ipairs(order_renames(ren_all, dels_by_path)) do
        ops[#ops + 1] = op
    end
    for _, op in ipairs(create_ops) do
        if not op.dir then
            ops[#ops + 1] = op
        end
    end
    for _, d in ipairs(dels) do
        if not d.consumed then
            ops[#ops + 1] = { kind = "delete", from = d.path }
        end
    end

    -- Static collision pass: a target that is ALSO claimed by another op in this batch is a
    -- user mistake the panel must show (on-disk collisions are the ops engine's runtime job).
    local claimed = {}
    for _, op in ipairs(ops) do
        if op.to then
            if claimed[op.to] then
                op.note = op.note or "target claimed twice"
            else
                claimed[op.to] = true
            end
        end
    end
    return ops
end

return M
