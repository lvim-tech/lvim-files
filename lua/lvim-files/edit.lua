-- lvim-files.edit: the editable-buffer view (the mini.files / fyler role). A directory opens
-- as a MODIFIABLE buffer in a centred lvim-ui float: one `icon name` line per entry, each
-- line carrying its entry's stable node id as a HIDDEN EXTMARK (the mark's own id IS the
-- node id, `invalidate`d when its line is deleted). Editing the text edits the filesystem —
-- on save (`:w` / the synchronize key) the buffer is diffed against the rendered base BY
-- extmark id (fs/diff.lua: rename / create / delete, with yank-tracking + name pairing that
-- turn `dd`…`p` into a MOVE and a duplicated line into a COPY), the ordered op list is shown
-- in a confirm panel, applied through the ops engine, and the view rescans.
--
-- Navigation re-targets the SAME buffer (go_in on a directory line, go_out to the parent);
-- each visited directory's pending text is snapshotted and restored, so one sync can apply
-- edits made across several directories — that cross-view session is what makes moves work.
--
---@module "lvim-files.edit"

local config = require("lvim-files.config")
local diff = require("lvim-files.fs.diff")
local git = require("lvim-files.fs.git")
local model = require("lvim-files.fs.model")
local ops = require("lvim-files.fs.ops")
local render = require("lvim-files.render")
local surface = require("lvim-ui.surface")
local lvim_ui = require("lvim-ui")
local lvim_cursor = require("lvim-utils.cursor")

local api = vim.api

local M = {}

local NS_ID = api.nvim_create_namespace("LvimFilesEditIds") -- the per-line identity marks
local NS_HL = api.nvim_create_namespace("LvimFilesEditHl") -- icon / name decorations

---@class LvimFilesEditViewState
---@field node LvimFilesNode                     the directory's model root
---@field base table<integer, { name: string, type: string }>  node id → identity as rendered
---@field snapshot? { lines: string[], ids: table<integer, integer>, spans: table<integer, table[]> }  pending text + decorations (set on leave)

---@class LvimFilesEditState
local state = {
    surface = nil, ---@type table|nil
    st = nil, ---@type table|nil            the frame state (set_title / relayout)
    buf = nil, ---@type integer|nil
    win = nil, ---@type integer|nil
    dir = nil, ---@type string|nil          the directory the buffer currently targets
    base_dir = nil, ---@type string|nil     the shallowest visited dir (breadcrumb base)
    views = {}, ---@type table<string, LvimFilesEditViewState>
    yanks = {}, ---@type table<string, { path: string, dir: boolean }>  raw line text → source
    opener = nil, ---@type integer|nil      the window the view opened from
    opening = false, ---@type string|false  a dir while an open() is mid-scan (its surface not built yet)
    augroup = nil, ---@type integer|nil
    show_dotfiles = true, ---@type boolean  filter: show entries whose name starts with "."
    show_gitignore = true, ---@type boolean filter: show git-ignored entries
}

--- The live edit config.
---@return LvimFilesEditConfig
local function cfg()
    return config.edit
end

--- Whether a node passes the active dot / gitignore filters. A HIDDEN node is left out of the render AND
--- the diff base, so `synchronize` never sees it — hidden entries are untouched on disk.
---@param node LvimFilesNode
---@return boolean
local function visible(node)
    if not state.show_dotfiles and node.name:sub(1, 1) == "." then
        return false
    end
    if not state.show_gitignore and git.is_ignored(node.path) then
        return false
    end
    return true
end

--- The first configured key label for a mapping (a bar's lead badge).
---@param lhs string|string[]
---@return string
local function key_label(lhs)
    if type(lhs) == "table" then
        return lhs[1] or "?"
    end
    return lhs or "?"
end

--- Whether the edit view is open.
---@return boolean
function M.is_open()
    return state.win ~= nil and api.nvim_win_is_valid(state.win)
end

-- ── view bookkeeping ──────────────────────────────────────────────────────────

--- The view state for a directory, created on first visit.
---@param dir string
---@return LvimFilesEditViewState
local function view_for(dir)
    local v = state.views[dir]
    if not v then
        v = { node = model.root(dir), base = {} }
        state.views[dir] = v
    end
    return v
end

--- Read the CURRENT per-line identity map from the buffer's extmarks (invalidated marks —
--- their line was deleted — are skipped; a joined line keeps only its first mark).
---@return table<integer, integer>  line (1-based) → node id
local function read_ids()
    local ids = {}
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return ids
    end
    for _, m in ipairs(api.nvim_buf_get_extmarks(state.buf, NS_ID, 0, -1, { details = true })) do
        local row, det = m[2] + 1, m[4]
        if not (det and det.invalid) and ids[row] == nil then
            ids[row] = m[1]
        end
    end
    return ids
end

--- Read the buffer's CURRENT decoration extmarks (NS_HL: icon / name colours) back into the `spans`
--- shape write_buffer consumes (`line 1-based → { {c0, c1, hl}, … }`), so a snapshot can restore the exact
--- colours on return — otherwise a snapshot-restored dir clears NS_HL and re-paints nothing (icons go plain).
---@return table<integer, table[]>
local function read_spans()
    local spans = {}
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return spans
    end
    for _, m in ipairs(api.nvim_buf_get_extmarks(state.buf, NS_HL, 0, -1, { details = true })) do
        local row, col, det = m[2] + 1, m[3], m[4]
        if det and det.hl_group and det.end_col then
            spans[row] = spans[row] or {}
            spans[row][#spans[row] + 1] = { col, det.end_col, det.hl_group }
        end
    end
    return spans
end

--- Snapshot the buffer's pending text for the CURRENT directory (called before leaving it
--- and before a sync, so every visited dir contributes its edits).
local function snapshot_current()
    if not (state.dir and state.buf and api.nvim_buf_is_valid(state.buf)) then
        return
    end
    local v = state.views[state.dir]
    if v then
        v.snapshot = { lines = api.nvim_buf_get_lines(state.buf, 0, -1, false), ids = read_ids(), spans = read_spans() }
    end
end

--- The breadcrumb border-title for a directory: path segments from the shallowest visited
--- dir, joined with ➤ (the canonical sequence separator).
---@param dir string
---@return string
local function breadcrumb(dir)
    local base = state.base_dir or dir
    local prefix = base == "/" and "/" or (base .. "/")
    local segs = { vim.fn.fnamemodify(base, ":t") }
    if segs[1] == "" then
        segs[1] = "/"
    end
    if dir ~= base and dir:sub(1, #prefix) == prefix then
        for comp in dir:sub(#prefix + 1):gmatch("[^/]+") do
            segs[#segs + 1] = comp
        end
    end
    return table.concat(segs, " ➤ ")
end

--- Fit the breadcrumb into `avail` display cells, keeping the TAIL (the current folder) visible: a deep
--- chain that overflows the panel (already widened to its max) is scrolled — truncated from the LEFT with a
--- leading ellipsis — so the current directory stays on screen instead of being clipped off the right.
---@param bc string
---@param avail integer
---@return string
local function fit_title(bc, avail)
    if avail <= 1 or vim.fn.strdisplaywidth(bc) <= avail then
        return bc
    end
    local chars = vim.fn.strchars(bc)
    for i = 1, chars - 1 do
        local suf = vim.fn.strcharpart(bc, i)
        if vim.fn.strdisplaywidth(suf) <= avail - 1 then -- -1 leaves room for the "…"
            return "…" .. suf
        end
    end
    return bc
end

--- Write `lines` (+ identity marks + decorations) into the buffer, resetting undo history —
--- an undo must never cross a re-target/rescan boundary (it would resurrect lines whose
--- identity marks are gone).
---@param lines string[]
---@param ids table<integer, integer>       line → node id
---@param spans? table<integer, table[]>    line → { {c0,c1,hl}, … }
local function write_buffer(lines, ids, spans)
    local buf = state.buf
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    local ul = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].undolevels = ul
    api.nvim_buf_clear_namespace(buf, NS_ID, 0, -1)
    api.nvim_buf_clear_namespace(buf, NS_HL, 0, -1)
    for row, id in pairs(ids) do
        -- Default (RIGHT) gravity is load-bearing: a linewise paste inserts at (row, 0), and a
        -- left-gravity mark sitting exactly there would STAY on the pasted line — stealing the
        -- pushed-down entry's identity. With right gravity the mark follows its own line down.
        pcall(api.nvim_buf_set_extmark, buf, NS_ID, row - 1, 0, {
            id = id,
            invalidate = true,
        })
    end
    for row, ss in pairs(spans or {}) do
        for _, s in ipairs(ss) do
            pcall(api.nvim_buf_set_extmark, buf, NS_HL, row - 1, s[1], { end_col = s[2], hl_group = s[3] })
        end
    end
    vim.bo[buf].modified = false
end

---@type fun(counts: { dot: integer, ign: integer }): table   forward decl (defined below, uses the toggles)
local build_footer

--- Render (or restore) a directory into the buffer and refresh the chrome. `cb` fires after
--- the content landed (fresh renders scan asynchronously first).
---@param dir string
---@param cb? fun()
local function render_dir(dir, cb)
    local v = view_for(dir)
    local function finish()
        if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
            return
        end
        -- Filter-bar counts: how many of THIS dir's entries each filter governs (shown as the badge),
        -- regardless of whether they are currently shown.
        local counts = { dot = 0, ign = 0 }
        for _, ch in ipairs(v.node.children or {}) do
            if ch.name:sub(1, 1) == "." then
                counts.dot = counts.dot + 1
            end
            if git.is_ignored(ch.path) then
                counts.ign = counts.ign + 1
            end
        end
        if v.snapshot then
            write_buffer(v.snapshot.lines, v.snapshot.ids, v.snapshot.spans)
            vim.bo[state.buf].modified = true -- restored pending edits are still unsaved
            v.snapshot = nil
        else
            local lines, ids, spans = {}, {}, {}
            v.base = {}
            -- A hidden (filtered-out) entry is written NEITHER to the buffer NOR to `v.base`, so the
            -- synchronize diff never sees it and leaves it untouched on disk.
            local n = 0
            for _, ch in ipairs(v.node.children or {}) do
                if visible(ch) then
                    n = n + 1
                    local line, ss = render.edit_line(ch)
                    lines[n] = line
                    ids[n] = ch.id
                    spans[n] = ss
                    v.base[ch.id] = { name = ch.name, type = ch.type }
                end
            end
            write_buffer(lines, ids, spans)
        end
        pcall(api.nvim_buf_set_name, state.buf, "lvim-files://" .. dir)
        if state.st then
            -- Resize FIRST (the size fn now widens to fit the breadcrumb, clamped to the panel's max), THEN
            -- title it to the ACTUAL width: while the chain fits, the whole breadcrumb shows; once it overflows
            -- the maxed-out panel, fit_title scrolls it to the tail so the current folder stays visible. `+2`
            -- for the border-title's edge gutters (the frame spans a touch wider than the content window).
            if state.st.relayout then
                state.st.relayout()
            end
            if state.st.set_title then
                local avail = (state.win and api.nvim_win_is_valid(state.win))
                        and (api.nvim_win_get_width(state.win) + 2)
                    or 9999
                state.st.set_title(fit_title(breadcrumb(dir), avail))
            end
            if state.st.set_footer then
                state.st.set_footer(build_footer(counts))
            end
        end
        if cb then
            cb()
        end
    end
    if v.snapshot or v.node.loaded then
        finish()
    else
        model.load(v.node, finish)
    end
end

--- Flip the dotfiles filter and re-render the current directory (which rebuilds the buffer + the footer).
local function toggle_dotfiles()
    state.show_dotfiles = not state.show_dotfiles
    if state.dir then
        render_dir(state.dir)
    end
end

--- Flip the gitignore filter and re-render the current directory.
local function toggle_gitignore()
    state.show_gitignore = not state.show_gitignore
    if state.dir then
        render_dir(state.dir)
    end
end

--- One filter toggle button — the toggle KEY as the lead badge, the label lit when the entries are SHOWN
--- (active) and dim when hidden, plus a live count. Same box style as the tree panel's filter bar.
---@param label string
---@param key string
---@param active boolean
---@param count integer
---@param run fun()
---@return table
local function filter_button(label, key, active, count, run)
    local box = {
        icon = {
            padding = { 1, 1 },
            normal = "LvimFilesFilterKey",
            active = "LvimFilesFilterKey",
            hover = "LvimFilesFilterKey",
            hover_active = "LvimFilesFilterKey",
        },
        text = {
            padding = { 1, 1 },
            normal = "LvimFilesFilterOff",
            active = "LvimFilesFilterOn",
            hover = "LvimFilesFilterOff",
            hover_active = "LvimFilesFilterOn",
        },
    }
    return surface.button(
        { name = label, key = key, style = "action", active = active, count = count, run = run, hl = box },
        "action"
    )
end

--- Re-target the buffer to another directory (snapshotting the current one's edits).
---@param dir string
local function retarget(dir)
    dir = model.normalize(dir)
    snapshot_current()
    state.dir = dir
    if state.base_dir == nil then
        state.base_dir = dir
    elseif state.base_dir ~= dir then
        -- Walking above the old base rebases the breadcrumb.
        local prefix = dir == "/" and "/" or (dir .. "/")
        if state.base_dir:sub(1, #prefix) == prefix or dir == "/" then
            state.base_dir = dir
        end
    end
    render_dir(dir, function()
        if state.win and api.nvim_win_is_valid(state.win) then
            pcall(api.nvim_win_set_cursor, state.win, { 1, 0 })
        end
    end)
end

-- ── diff / apply ──────────────────────────────────────────────────────────────

--- The pending op list across every visited directory (snapshots the current one first).
---@return LvimFilesOp[]
local function pending_ops()
    snapshot_current()
    ---@type LvimFilesEditView[]
    local views = {}
    for dir, v in pairs(state.views) do
        if v.snapshot then
            views[#views + 1] = { dir = dir, lines = v.snapshot.lines, ids = v.snapshot.ids, base = v.base }
        end
    end
    table.sort(views, function(a, b)
        return a.dir < b.dir
    end)
    return diff.compute(views, state.yanks)
end

--- Apply an op list through the ops engine (in order; conflict-noted ops are skipped), then
--- reset the whole session and rescan the current directory.
---@param op_list LvimFilesOp[]
local function apply_ops(op_list)
    local applied, errors = 0, {}
    for _, op in ipairs(op_list) do
        if op.note then
            errors[#errors + 1] = ("skipped %s %s (%s)"):format(op.kind, op.to or op.from or "?", op.note)
        else
            local ok, err
            if op.kind == "create" then
                ok, err = ops.create(op.to, op.dir)
            elseif op.kind == "rename" or op.kind == "move" then
                ok, err = ops.rename(op.from, op.to)
            elseif op.kind == "copy" then
                ok, err = ops.copy(op.from, op.to)
            elseif op.kind == "delete" then
                ok, err = ops.delete(op.from)
            end
            if ok then
                applied = applied + 1
            else
                errors[#errors + 1] = err or (op.kind .. " failed")
            end
        end
    end
    for _, v in pairs(state.views) do
        model.release(v.node)
    end
    state.views = {}
    state.yanks = {}
    if state.dir then
        git.refresh(state.dir)
        render_dir(state.dir)
    end
    if #errors > 0 then
        vim.notify("lvim-files: " .. table.concat(errors, "\n"), vim.log.levels.WARN)
    elseif applied > 0 then
        vim.notify(("lvim-files: applied %d operation%s."):format(applied, applied == 1 and "" or "s"))
    end
end

-- Op kind → the confirm-row accent family (Add / Change / Delete).
---@type table<string, string>
local OP_FAMILY = {
    create = "Add",
    copy = "Change",
    rename = "Change",
    move = "Change",
    delete = "Delete",
}

--- Show the ordered op list in the confirm panel (the help-window canon: full-width tinted
--- rows, the active row raised to the strong tint; hidden cursor). `<CR>` applies.
---@param op_list LvimFilesOp[]
local function confirm_ops(op_list)
    local base = state.base_dir or state.dir or ""
    local prefix = base == "/" and "/" or (base .. "/")
    local function short(p)
        if p and p:sub(1, #prefix) == prefix then
            return p:sub(#prefix + 1)
        end
        return p and vim.fn.fnamemodify(p, ":~") or ""
    end
    local rows, kw = {}, 0
    for _, op in ipairs(op_list) do
        local detail
        if op.kind == "create" then
            detail = short(op.to) .. (op.dir and "/" or "")
        elseif op.kind == "delete" then
            detail = short(op.from) .. (ops.uses_trash() and "  (trash)" or "")
        else
            detail = short(op.from) .. " ➤ " .. short(op.to)
        end
        if op.note then
            detail = detail .. "   " .. op.note
        end
        rows[#rows + 1] = { verb = op.kind, detail = detail, family = OP_FAMILY[op.kind] or "Change" }
        kw = math.max(kw, #op.kind)
    end
    local keybox = kw + 4
    local dw = 0
    for _, r in ipairs(rows) do
        dw = math.max(dw, vim.fn.strdisplaywidth(r.detail))
    end

    local pan
    local provider = {
        hide_cursor = true,
        size = function()
            return math.min(keybox + dw + 4, math.floor(vim.o.columns * 0.9)), #rows
        end,
        render = function(width)
            local cur = (pan and pan.win and api.nvim_win_is_valid(pan.win)) and api.nvim_win_get_cursor(pan.win)[1]
                or 1
            local lines, hls = {}, {}
            for i, r in ipairs(rows) do
                local kcell = "  " .. r.verb
                kcell = kcell .. string.rep(" ", math.max(0, keybox - vim.fn.strdisplaywidth(kcell)))
                local dcell = "  " .. r.detail
                dcell = dcell .. string.rep(" ", math.max(0, width - keybox - vim.fn.strdisplaywidth(dcell)))
                lines[i] = kcell .. dcell
                local body = "LvimFilesOp" .. r.family .. (i == cur and "Active" or "")
                hls[#hls + 1] = { i - 1, 0, #kcell, "LvimFilesOp" .. r.family .. "Active" }
                hls[#hls + 1] = { i - 1, #kcell, #lines[i], body }
            end
            return lines, hls
        end,
        keys = function(map, p, st)
            pan = p
            api.nvim_create_autocmd("CursorMoved", {
                buffer = p.buf,
                callback = function()
                    if p.refresh then
                        p.refresh()
                    end
                end,
            })
            map({ "<CR>" }, function()
                st.close()
                vim.schedule(function()
                    apply_ops(op_list)
                end)
            end)
        end,
    }
    surface.open({
        mode = "float",
        border = surface.FRAME_BORDER,
        title = ("Apply %d operation%s"):format(#op_list, #op_list == 1 and "" or "s"),
        title_pos = "center",
        panel_border = "none",
        size = { width = { auto = true, max = 0.9 }, height = { auto = true, max = 0.7 } },
        content = { blocks = { { id = "ops", provider = provider } } },
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        {
                            key = "<CR>",
                            name = "apply",
                            run = function(st)
                                st.close()
                                vim.schedule(function()
                                    apply_ops(op_list)
                                end)
                            end,
                        },
                        {
                            key = "<Esc>",
                            name = "cancel",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
    })
end

--- Synchronize: diff every visited view, confirm (per config), apply.
local function synchronize()
    local op_list = pending_ops()
    if #op_list == 0 then
        if state.buf and api.nvim_buf_is_valid(state.buf) then
            vim.bo[state.buf].modified = false
        end
        vim.notify("lvim-files: no changes.", vim.log.levels.INFO)
        return
    end
    if cfg().confirm == false then
        apply_ops(op_list)
    else
        confirm_ops(op_list)
    end
end

--- Defer synchronize a tick. The confirm panel is a CHILD surface; opening it synchronously from
--- inside the edit float's own keymap callback (or a BufWriteCmd context) loses focus the moment
--- control returns to the modal, so the panel never stays up. Scheduling opens it cleanly — the `:w`
--- handler already relied on this; the `=` key and the footer button must do the same.
local function request_sync()
    vim.schedule(synchronize)
end

-- ── navigation ────────────────────────────────────────────────────────────────

--- The node behind the cursor line (nil for a created / not-yet-applied line).
---@return LvimFilesNode|nil
local function cursor_node()
    if not M.is_open() then
        return nil
    end
    local line = api.nvim_win_get_cursor(state.win)[1]
    local id = read_ids()[line]
    return id and model.node(id) or nil
end

--- The fs entry under the edit-view cursor as a gx-style descriptor (nil on a created / not-yet-applied
--- line). Public seam for external "open under cursor" integrations — the edit buffer (ft
--- `lvim-files-edit`) has the same precise node seam as the tree, so gx routes here instead of scanning
--- the rendered `icon name` text with no directory context.
---@return { path: string, type: "dir"|"file" }|nil
function M.entry_under_cursor()
    local node = cursor_node()
    if not node then
        return nil
    end
    return { path = node.path, type = model.is_dir(node) and "dir" or "file" }
end

--- go_in: re-target into a directory line; open a file line (guarding pending edits).
local function go_in()
    local node = cursor_node()
    if not node then
        vim.notify("lvim-files: entry not applied yet — synchronize first.", vim.log.levels.INFO)
        return
    end
    if model.is_dir(node) then
        retarget(node.path)
        return
    end
    local path = node.path
    local opener = state.opener
    local function open_it()
        M.close(true)
        if opener and api.nvim_win_is_valid(opener) then
            api.nvim_set_current_win(opener)
        end
        vim.cmd.edit(vim.fn.fnameescape(path))
    end
    if #pending_ops() > 0 then
        lvim_ui.confirm({
            title = "Discard pending changes?",
            default_no = true,
            callback = function(yes)
                if yes then
                    open_it()
                end
            end,
        })
    else
        open_it()
    end
end

--- go_out: re-target to the parent directory.
local function go_out()
    if state.dir then
        local parent = vim.fs.dirname(state.dir)
        if parent and parent ~= state.dir then
            retarget(parent)
        end
    end
end

--- Close, guarding pending (unapplied) operations behind a confirm.
local function request_close()
    local n = #pending_ops()
    if n == 0 then
        M.close(true)
        return
    end
    lvim_ui.confirm({
        title = ("Discard %d pending operation%s?"):format(n, n == 1 and "" or "s"),
        default_no = true,
        callback = function(yes)
            if yes then
                M.close(true)
            end
        end,
    })
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

--- The display label for a `string|string[]` key spec (footer hint chips).
---@param lhs string|string[]|nil
---@return string
local function key_hint(lhs)
    if type(lhs) == "table" then
        return table.concat(lhs, "/")
    end
    return lhs or "?"
end

--- Buffer-local autocmds: `:w` = synchronize; every yank/delete records the affected lines'
--- identities so a later paste is recognised as a MOVE / COPY of those entries.
local function setup_autocmds()
    state.augroup = api.nvim_create_augroup("LvimFilesEdit", { clear = true })
    api.nvim_create_autocmd("BufWriteCmd", {
        group = state.augroup,
        buffer = state.buf,
        callback = function()
            -- Deferred (request_sync): BufWriteCmd runs in a restored-window autocmd context, so the
            -- confirm panel focused INSIDE it would lose focus the moment the :write returns.
            request_sync()
        end,
    })
    api.nvim_create_autocmd("TextYankPost", {
        group = state.augroup,
        buffer = state.buf,
        callback = function()
            if not state.dir then
                return
            end
            local v = state.views[state.dir]
            if not v then
                return
            end
            local first = api.nvim_buf_get_mark(state.buf, "[")[1]
            local last = api.nvim_buf_get_mark(state.buf, "]")[1]
            if first == 0 or last == 0 then
                return
            end
            local ids = read_ids()
            local lines = api.nvim_buf_get_lines(state.buf, first - 1, last, false)
            for i, line in ipairs(lines) do
                local id = ids[first + i - 1]
                local b = id and v.base[id]
                if b then
                    local raw = vim.trim(line)
                    if raw ~= "" then
                        state.yanks[raw] = { path = model.join(state.dir, b.name), dir = b.type == "directory" }
                    end
                end
            end
        end,
    })
end

--- The edit view footer: the dot / git filter toggles (top row, like the tree panel) + the action hints
--- (bottom row). Rebuilt on every render / navigation / toggle (via `render_dir` → `st.set_footer`).
---@param counts { dot: integer, ign: integer }
---@return table
build_footer = function(counts)
    local ek = cfg().keys
    return {
        bars = {
            {
                align = "center",
                items = {
                    filter_button(
                        "Dot",
                        key_label(ek.toggle_dotfiles),
                        state.show_dotfiles,
                        counts.dot,
                        toggle_dotfiles
                    ),
                    { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiPeekFilterSep" } },
                    filter_button(
                        "Git",
                        key_label(ek.toggle_gitignore),
                        state.show_gitignore,
                        counts.ign,
                        toggle_gitignore
                    ),
                },
            },
            {
                align = "center",
                items = {
                    { key = key_hint(ek.synchronize), name = "sync", no_hotkey = true, run = request_sync },
                    { key = key_hint(ek.go_in), name = "enter", no_hotkey = true, run = go_in },
                    { key = key_hint(ek.go_out), name = "up", no_hotkey = true, run = go_out },
                    { key = key_hint(ek.close), name = "close", no_hotkey = true, run = request_close },
                },
            },
        },
    }
end

--- Open the edit view on `dir` (default: the current file's directory, else the cwd). An
--- already-open view re-targets.
---@param dir? string
function M.open(dir)
    if dir == nil or dir == "" then
        local name = api.nvim_buf_get_name(0)
        if name == "" then
            dir = vim.fn.getcwd()
        elseif vim.fn.isdirectory(name) == 1 then
            dir = name
        else
            dir = vim.fs.dirname(name)
        end
    end
    dir = model.normalize(dir)
    if vim.fn.isdirectory(dir) == 0 then
        vim.notify("lvim-files: not a directory: " .. dir, vim.log.levels.ERROR)
        return
    end
    if M.is_open() then
        retarget(dir)
        api.nvim_set_current_win(state.win)
        return
    end
    -- Open latch: the surface is built only inside the async `model.load` callback below, but `M.is_open()`
    -- reads `state.win`, which is not set until that callback runs. Two rapid opens (or `:LvimFiles edit`
    -- twice during a slow scan of a huge directory) would both pass the guard and build TWO surfaces — the
    -- first handle overwritten in `state.surface`, un-closeable. The latch holds the LATEST requested dir so
    -- the in-flight open lands on it instead of spawning a second surface.
    if state.opening then
        state.opening = dir
        return
    end
    state.opening = dir
    state.opener = api.nvim_get_current_win()
    state.base_dir = dir
    -- Seed the filters from config (same defaults as the tree panel; `.` / `H` toggle them live).
    state.show_dotfiles = config.filters.dotfiles ~= false
    state.show_gitignore = config.filters.gitignore ~= false

    -- Pre-load the first listing so the float opens already sized to its content.
    local v = view_for(dir)
    model.load(v.node, function()
        local ek = cfg().keys
        local provider = {
            -- The NEUTRAL cursorline (bg-tint only), like the tree panel — NOT the float default
            -- `LvimUiPeekCursorLine`, whose yellow fg would repaint the row's icon + name. The active row
            -- reads as a tinted background while every icon / name keeps its own colour.
            cursorline = "LvimUiCursorLine",
            size = function()
                local w, h = 40, 1
                local dir_now = state.dir or dir
                local node = state.views[dir_now] and state.views[dir_now].node
                for _, ch in ipairs((node and node.children) or v.node.children or {}) do
                    w = math.max(w, vim.fn.strdisplaywidth(ch.name) + 8)
                    h = h + 1
                end
                -- Also widen to fit the breadcrumb border-title as the chain grows (the surface clamps this to
                -- its max width; beyond that the title is scrolled to the tail — see fit_title in render_dir).
                w = math.max(w, vim.fn.strdisplaywidth(breadcrumb(dir_now)) + 6)
                return w, math.max(1, h - 1)
            end,
            update = function(pan)
                -- The provider OWNS the buffer: capture the window pair once; re-fires on
                -- relayout/resize must never rewrite the (possibly edited) text.
                if state.buf ~= pan.buf then
                    state.buf, state.win = pan.buf, pan.win
                    vim.bo[pan.buf].buftype = "acwrite"
                    vim.bo[pan.buf].swapfile = false
                    vim.bo[pan.buf].filetype = "lvim-files-edit"
                    vim.bo[pan.buf].modifiable = true
                    -- This is a self-documenting modal (its own keymaps + footer legend). Opt OUT of the
                    -- lvim-keys-helper peek so a buffer-local `nowait` key that is ALSO a global prefix
                    -- (e.g. `=` synchronize vs the global `==`) fires immediately instead of raising the
                    -- helper's disambiguation popup.
                    vim.b[pan.buf].lvim_keys_helper_disable = true
                    -- Hide the hardware cursor while the edit buffer is the current window (the cursorline marks
                    -- the row), matching the tree panel. It STAYS editable, so the cursor must come back to see
                    -- what is typed: the input-buffer exemption (highest precedence in lvim-utils.cursor) shows it
                    -- in INSERT mode and re-hides on leave. Both marks are auto-cleared when the buffer is wiped
                    -- on close (the cursor module's BufWipeout cleanup), and the buffer-local autocmds go with it.
                    lvim_cursor.mark_hide_buffer(pan.buf, true)
                    local cgrp = api.nvim_create_augroup("LvimFilesEditCursor", { clear = true })
                    api.nvim_create_autocmd("InsertEnter", {
                        group = cgrp,
                        buffer = pan.buf,
                        callback = function()
                            lvim_cursor.mark_input_buffer(pan.buf, true)
                        end,
                    })
                    api.nvim_create_autocmd("InsertLeave", {
                        group = cgrp,
                        buffer = pan.buf,
                        callback = function()
                            lvim_cursor.mark_input_buffer(pan.buf, false)
                        end,
                    })
                end
                state.win = pan.win
            end,
            keys = function(map, pan, st)
                state.buf, state.win, state.st = pan.buf, pan.win, st
                map(ek.go_in, go_in)
                map(ek.go_out, go_out)
                map(ek.synchronize, request_sync)
                map(ek.close, request_close)
                map(ek.toggle_dotfiles, toggle_dotfiles)
                map(ek.toggle_gitignore, toggle_gitignore)
            end,
            on_close = function()
                if state.augroup then
                    pcall(api.nvim_del_augroup_by_id, state.augroup)
                    state.augroup = nil
                end
                for _, vv in pairs(state.views) do
                    model.release(vv.node)
                end
                state.views, state.yanks = {}, {}
                state.opening = false
                state.buf, state.win, state.st, state.surface, state.dir, state.base_dir = nil, nil, nil, nil, nil, nil
            end,
        }
        state.surface = surface.open({
            mode = "float",
            border = surface.FRAME_BORDER,
            title = breadcrumb(dir),
            title_pos = "center", -- the breadcrumb is retitled live via st.set_title on navigation
            panel_border = "none",
            size = { width = { auto = true, max = 0.7 }, height = { auto = true, max = 0.7, min = 5 } },
            -- A left/right 1-cell blank inset (`" "` edges draw no glyph — pure padding) so the icon + name
            -- content does not touch the frame edges, mirroring the top/bottom air. The buffer text itself
            -- stays clean ("icon name") — the padding is border geometry, not buffer content, so editing /
            -- synchronize are unaffected.
            content = {
                blocks = { { id = "edit", provider = provider, border = { "", "", "", " ", "", "", "", " " } } },
            },
            close_keys = {}, -- <Esc> must stay plain insert-leave; the close key guards pending ops
            -- The filter toggles + action hints; render_dir refreshes it with the live per-dir counts.
            footer = build_footer({ dot = 0, ign = 0 }),
        })
        state.dir = dir
        setup_autocmds()
        -- Release the latch. If another open() arrived for a DIFFERENT directory while this scan was in
        -- flight, honour it now (retarget the freshly built surface) instead of having spawned a second one.
        local pending = state.opening
        state.opening = false
        if type(pending) == "string" and pending ~= dir then
            retarget(pending)
        else
            render_dir(dir)
        end
        git.refresh(state.dir or dir)
    end)
end

--- Close the edit view. With `force`, pending edits are discarded without asking (M.close
--- is also what the frame teardown funnels into).
---@param force? boolean
function M.close(force)
    if not state.surface then
        return
    end
    if not force and #pending_ops() > 0 then
        request_close()
        return
    end
    local f = state.surface
    state.surface = nil
    if f then
        pcall(f.close)
    end
end

--- Toggle the edit view.
---@param dir? string
function M.toggle(dir)
    if M.is_open() then
        M.close()
    else
        M.open(dir)
    end
end

return M
