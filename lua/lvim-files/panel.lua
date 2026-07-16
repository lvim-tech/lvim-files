-- lvim-files.panel: the persistent tree side panel (the neo-tree role). A NATIVE split
-- surface pinned to one edge (winfixwidth, NormalSB background) — the same window class as
-- the lvim-lsp outline: a plain window the plugin owns, whose buffer carries the
-- "lvim-files" filetype so the user's cursor `panel_ft` registration hides the hardware
-- cursor while the panel is current. The TREE itself renders through the SHARED
-- `lvim-ui.tree` primitive (fold state, guides/markers, badges, scrollbar, canonical keys +
-- mouse); this module owns the fs model/git/diagnostics data, the filters, the file actions
-- and the popups (add/rename inputs, delete confirm, help — all through lvim-ui, so it
-- themes and keys like the rest of the set). The root-path band sits at the TOP of the
-- buffer (the tree's `header` rows); the filter bar (dot / git toggles) rides the surface's
-- native-split FOOTER (`footer = { bars = … }` + `set_footer` for live counts) — a bar
-- lvim-ui pins to the panel's bottom row, so it stays visible however far the tree scrolls.
-- Git/diagnostic badges sit right-aligned as virtual text (tree node `badges`).
--
---@module "lvim-files.panel"

local config = require("lvim-files.config")
local model = require("lvim-files.fs.model")
local git = require("lvim-files.fs.git")
local ops = require("lvim-files.fs.ops")
local render = require("lvim-files.render")
local surface = require("lvim-ui.surface")
local lvim_ui = require("lvim-ui")
local uhl = require("lvim-utils.highlight")

local api = vim.api
local uv = vim.uv

local M = {}

---@class LvimFilesPanelState
local state = {
    surface = nil, ---@type table|nil        the surface handle
    win = nil, ---@type integer|nil          the panel window
    buf = nil, ---@type integer|nil          the panel buffer
    root = nil, ---@type LvimFilesNode|nil   the tree root
    panel = nil, ---@type table|nil          the lvim-ui.tree handle (the shared tree content layer)
    watched = {}, ---@type table<string, LvimFilesNode>  path → watched dir node
    seeded = false, ---@type boolean         filters seeded from config (once per session)
    show_dotfiles = true, ---@type boolean
    show_gitignore = true, ---@type boolean
    -- The file clipboard: a MODE plus the entries it holds. A list, not a single path — copying one file and
    -- copying a visual selection of ten are the same operation, and neo-tree-style "select, y, paste" is what
    -- a file tree is for. Entries are `{ path, name }`.
    clipboard = nil, ---@type { mode: "copy"|"cut", items: { path: string, name: string }[] }|nil
    diag = {}, ---@type table<string, integer>  path → worst severity
    augroup = nil, ---@type integer|nil
    unsub = {}, ---@type fun()[]             model/git listener unsubscribers
    diag_timer = nil, ---@type uv.uv_timer_t|nil
    opener = nil, ---@type integer|nil       the last real editor window (files open there)
    followed = nil, ---@type string|nil      the last path revealed by follow-current-file (dedup guard)
}

--- The live panel config.
---@return LvimFilesPanelConfig
local function cfg()
    return config.panel
end

---@param w integer|nil
---@return boolean
local function is_valid_win(w)
    return w ~= nil and api.nvim_win_is_valid(w)
end

--- Whether the panel is open.
---@return boolean
function M.is_open()
    return is_valid_win(state.win)
end

--- The first key of a `string|string[]` key spec (for display in bars/help).
---@param lhs string|string[]|nil
---@return string
local function key_label(lhs)
    if type(lhs) == "table" then
        return lhs[1] or "?"
    end
    return lhs or "?"
end

-- ── filtering ─────────────────────────────────────────────────────────────────

--- Whether a node passes the active filters.
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

-- ── watching / loading ────────────────────────────────────────────────────────

--- Watch a directory node (tracked so close releases everything).
---@param node LvimFilesNode
local function watch(node)
    if not state.watched[node.path] then
        state.watched[node.path] = node
        model.watch(node)
    end
end

---@param node LvimFilesNode
local function unwatch(node)
    if state.watched[node.path] then
        state.watched[node.path] = nil
        model.unwatch(node)
    end
end

--- Coalesced repaint — delegates to the shared tree's queue (bursts of async loads / git
--- refreshes collapse into one repaint on the next tick).
local function schedule_render()
    if state.panel then
        state.panel.refresh()
    end
end

--- Ensure an expanded directory is loaded; renders again once the scan lands.
---@param node LvimFilesNode
local function ensure_loaded(node)
    if node.loaded or node._loading then
        return
    end
    node._loading = true
    model.load(node, function()
        node._loading = nil
        git.refresh(node.path)
        schedule_render()
    end)
end

-- ── header bands (root path + filter bar, via the lvim-ui primitives) ─────────

--- Toggle handlers are declared before the band builder so the buttons can reference them.
local function toggle_dotfiles()
    state.show_dotfiles = not state.show_dotfiles
    schedule_render()
end

local function toggle_gitignore()
    state.show_gitignore = not state.show_gitignore
    schedule_render()
end

--- One filter toggle button: the real toggle KEY as the lead badge, the label lit when the
--- entries are SHOWN (active), dim when hidden — a live count of matching loaded entries.
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

local show_help -- forward decl (the footer's help chip is built before the window that opens it)

--- The filter band's element list: the two filter toggles and the HELP chip. No ● separators — the panel is
--- 34 columns wide and they cost the help chip its place; the panel's keys are not discoverable from the tree,
--- so the cheatsheet's key has to be on the bar.
---@param counts { dot: integer, ign: integer }
---@return table[]
local function filter_items(counts)
    local keys = cfg().keys
    return {
        filter_button("Dot", key_label(keys.toggle_dotfiles), state.show_dotfiles, counts.dot, toggle_dotfiles),
        filter_button("Git", key_label(keys.toggle_gitignore), state.show_gitignore, counts.ign, toggle_gitignore),
        surface.button({
            name = "help",
            key = key_label(keys.help),
            style = "action",
            run = function()
                show_help()
            end,
        }, "action"),
    }
end

--- The root path shown in the header band (home shortened to ~, then the tail kept whole).
---@param width integer
---@return string
local function root_label(width)
    local path = vim.fn.fnamemodify(state.root and state.root.path or "", ":~")
    local avail = width - 4
    if vim.fn.strdisplaywidth(path) > avail then
        path = "…" .. vim.fn.strcharpart(path, vim.fn.strchars(path) - (avail - 1))
    end
    return path
end

-- ── tree nodes (the lvim-ui.tree provider data) ──────────────────────────────

--- Map a model directory's (filtered) children into `lvim-ui.tree` nodes. Re-run per render —
--- directories hand the tree a LAZY `children` function, so only EXPANDED branches materialize and
--- every repaint re-decorates live (git badges, diagnostics, the cut strike-through). The model
--- node rides along as `data` (the actions read it back from `selected()`).
---@param node LvimFilesNode
---@return LvimUiTreeNode[]
local function to_nodes(node)
    local icons = config.icons
    -- Every entry that is on the CUT clipboard renders dimmed (it is about to move away).
    local cut = {}
    if state.clipboard and state.clipboard.mode == "cut" then
        for _, it in ipairs(state.clipboard.items) do
            cut[it.path] = true
        end
    end
    local out = {}
    for _, ch in ipairs(node.children or {}) do
        if visible(ch) then
            local is_dir = model.is_dir(ch)
            local expanded = is_dir and state.panel ~= nil and state.panel.expanded(ch.path)
            local glyph, icon_hl = render.node_icon(ch, expanded)

            -- Right-aligned badges: symlink marker + git status + worst contained diagnostic. The blank BETWEEN
            -- badges is a separator; there is deliberately NO trailing one — `lvim-ui.tree` insets right-aligned
            -- badges by its own right padding (and the scrollbar column), so a trailing blank here would just
            -- add a third gap before the bar.
            local badges = {}
            ---@param glyph string
            ---@param hl string|nil
            local function badge(glyph, hl)
                local g = hl or "LvimFilesEmpty"
                if #badges > 0 then
                    badges[#badges + 1] = { " ", g }
                end
                badges[#badges + 1] = { glyph, g }
            end
            if ch.type == "link" then
                badge(icons.symlink, "LvimFilesSymlink")
            end
            local gglyph, ghl = render.git_badge(ch.path)
            if gglyph then
                badge(gglyph, ghl)
            end
            local dglyph, dhl = render.diag_badge(state.diag[ch.path])
            if dglyph then
                badge(dglyph, dhl)
            end

            out[#out + 1] = {
                id = ch.path,
                label = ch.name,
                icon = glyph,
                icon_hl = icon_hl,
                label_hl = cut[ch.path] and "LvimFilesCut" or render.name_hl(ch),
                expandable = is_dir,
                children = is_dir and function()
                    ensure_loaded(ch) -- kick the async scan; renders again when it lands
                    return to_nodes(ch)
                end or nil,
                badges = #badges > 0 and badges or nil,
                data = ch,
            }
        end
    end
    return out
end

--- Repaint NOW (synchronous — before a focus/reveal that needs the fresh rows).
local function do_render()
    if state.panel and M.is_open() and state.root then
        ensure_loaded(state.root)
        state.panel.render()
    end
end

-- ── node actions ──────────────────────────────────────────────────────────────

--- The model node under the panel cursor (nil on the header/empty rows).
---@return LvimFilesNode|nil
local function cur_node()
    local ui = state.panel and state.panel.selected()
    return ui and ui.data or nil
end

--- The directory an add/paste under the cursor targets: the node itself when it is a
--- directory, else its parent (the root on the header rows).
---@return string
local function target_dir()
    local node = cur_node()
    if not node then
        return state.root.path
    end
    if model.is_dir(node) then
        return node.path
    end
    return node.parent and node.parent.path or vim.fs.dirname(node.path)
end

--- Reload a directory's listing (by path, when its node is loaded) and repaint.
---@param dir string
local function refresh_dir(dir)
    local node = state.root and (dir == state.root.path and state.root or model.find(state.root, dir))
    if node and model.is_dir(node) then
        model.load(node, schedule_render, true)
    else
        schedule_render()
    end
    git.refresh(dir)
end

--- Can a file be opened INTO this window? A normal file buffer, yes — and so is a PLACEHOLDER window
--- (`config.reuse_filetypes`, the start dashboard by default): it is a scratch buffer whose whole purpose is
--- to be replaced by the thing you pick, so opening a file beside it — and leaving it as a second window —
--- is precisely wrong.
---@param w integer
---@return boolean
local function is_openable_win(w)
    local b = api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == "" then
        return true
    end
    for _, ft in ipairs(cfg().reuse_filetypes or {}) do
        if vim.bo[b].filetype == ft then
            return true
        end
    end
    return false
end

--- A window suitable for opening files: the tracked opener, else the first usable window,
--- else a fresh split beside the panel.
---@return integer
local function usable_window()
    if is_valid_win(state.opener) and state.opener ~= state.win and is_openable_win(state.opener) then
        return state.opener
    end
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if w ~= state.win and api.nvim_win_get_config(w).relative == "" and is_openable_win(w) then
            return w
        end
    end
    local buf = api.nvim_create_buf(true, false)
    return api.nvim_open_win(buf, false, { split = cfg().side == "left" and "right" or "left", win = state.win })
end

--- Open a file node, honouring `auto_close_on_open`. `how` picks the target: nil/"edit" reuses `win`
--- (or a usable window); "vsplit"/"split" open a new split OF a usable window; "tab" a new tab.
---@param node LvimFilesNode
---@param win? integer
---@param how? "edit"|"vsplit"|"split"|"tab"
local function open_file(node, win, how)
    local esc = vim.fn.fnameescape(node.path)
    if how == "vsplit" or how == "split" then
        api.nvim_set_current_win(win or usable_window())
        vim.cmd((how == "vsplit" and "vsplit " or "split ") .. esc)
    elseif how == "tab" then
        vim.cmd("tabedit " .. esc)
    else
        api.nvim_set_current_win(win or usable_window())
        vim.cmd.edit(esc)
    end
    if cfg().auto_close_on_open then
        M.close()
    end
end

--- Open the file under the cursor via `how` ("vsplit"/"split"/"tab"); a no-op on a directory row.
---@param how "vsplit"|"split"|"tab"
local function open_current_as(how)
    local node = cur_node()
    if not node or model.is_dir(node) then
        return
    end
    open_file(node, nil, how)
end

--- With `auto_collapse`, keep only the branch leading to `keep_path` open: collapse every other
--- expanded directory (one that is neither `keep_path` itself nor an ancestor of it). A no-op when
--- the option is off. Collapses DEEPEST-first so every folding node is still reachable through its
--- (still-expanded) ancestors — the tree's `on_collapse` hook then releases each watcher reliably.
---@param keep_path string
local function collapse_others(keep_path)
    if not (cfg().auto_collapse and state.panel) then
        return
    end
    keep_path = model.normalize(keep_path)
    local close = {}
    for dpath, on in pairs(state.panel.expanded_state()) do
        if on then
            local keep = dpath == keep_path or keep_path:sub(1, #dpath + 1) == (dpath .. "/")
            if not keep then
                close[#close + 1] = dpath
            end
        end
    end
    table.sort(close, function(a, b)
        return #a > #b
    end)
    for _, dpath in ipairs(close) do
        state.panel.collapse(dpath)
    end
end

--- `open` on the current row: toggle a directory, open a file. (The tree's `on_expand` hook does
--- the watch + load + `collapse_others`; `on_collapse` releases the watcher.)
local function action_open()
    local node = cur_node()
    if not node then
        return
    end
    if model.is_dir(node) then
        state.panel.toggle(node.path)
    else
        open_file(node)
    end
end

--- Open the file under the cursor in a window chosen through lvim-winpick.
--- The windows a file may be opened INTO: every REAL window of the tab except the panel itself — floats and
--- chrome are out (`is_openable_win`), the placeholder dashboard is IN (that is what it is for). lvim-files
--- owns this rule, not the picker: winpick's own filters exclude the dashboard, which is exactly the window
--- we most want as a target.
---@return integer[]
local function open_targets()
    local out = {}
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if w ~= state.win and api.nvim_win_get_config(w).relative == "" and is_openable_win(w) then
            out[#out + 1] = w
        end
    end
    return out
end

--- Open the file under the cursor in a window CHOSEN with lvim-winpick (`panel.winpick`). With one candidate
--- winpick's `autoselect_one` returns it with no UI — a choice with one answer is not a question; with none,
--- `open_file` makes a split as usual. Cancelling the pick opens nothing. With the integration off, or with
--- lvim-winpick absent, this is a plain open.
local function action_open_pick()
    local node = cur_node()
    if not node or model.is_dir(node) then
        return
    end
    local ok, winpick = pcall(require, "lvim-winpick")
    if not (cfg().winpick and ok) then
        open_file(node)
        return
    end
    local targets = open_targets()
    if #targets == 0 then
        open_file(node) -- nothing to pick between: the usual "make a window" path
        return
    end
    -- The panel is the CURRENT window and never a target (include_current stays off); `filter_func` replaces
    -- winpick's eligibility with OURS, so the dashboard is offered and the chrome is not.
    local win = winpick.pick({
        filter_func = function()
            return targets
        end,
    })
    if win then
        open_file(node, win)
    end
end

--- A single-line text prompt — through the lvim-ui popup (`input="popup"`) or Neovim's native
--- `vim.ui.input` (`input="native"`), per config. The callback is `(confirmed, value)` either way.
---@param opts { title: string, default?: string, callback: fun(confirmed: boolean, value: string) }
local function text_input(opts)
    if cfg().input == "native" then
        vim.ui.input({ prompt = opts.title .. ": ", default = opts.default }, function(val)
            opts.callback(val ~= nil, val or "")
        end)
    else
        lvim_ui.input(opts)
    end
end

--- A byte count as a human-readable size.
---@param n integer
---@return string
local function human_size(n)
    local units = { "B", "K", "M", "G", "T" }
    local i, v = 1, n
    while v >= 1024 and i < #units do
        v = v / 1024
        i = i + 1
    end
    return i == 1 and ("%d B"):format(v) or ("%.1f %s"):format(v, units[i])
end

--- A uv mode integer as `rwxr-xr-x`.
---@param mode integer
---@return string
local function perm_string(mode)
    local bits = { "r", "w", "x" }
    local out = {}
    for shift = 6, 0, -3 do
        for b = 0, 2 do
            local mask = 2 ^ (shift + (2 - b))
            out[#out + 1] = (mode % (mask * 2) >= mask) and bits[b + 1] or "-"
        end
    end
    return table.concat(out)
end

--- The immediate entry count and the total size of a directory tree. Bounded: a deep tree is walked only
--- until `budget` entries, and the result says so — an info popup must never hang on `~/`.
---@param path string
---@param budget integer
---@return integer entries, integer bytes, boolean truncated
local function dir_stats(path, budget)
    local entries, bytes, seen = 0, 0, 0
    local stack = { path }
    while #stack > 0 do
        local dir = table.remove(stack)
        local fd = uv.fs_scandir(dir)
        if fd then
            while true do
                local name, kind = uv.fs_scandir_next(fd)
                if not name then
                    break
                end
                seen = seen + 1
                if seen > budget then
                    return entries, bytes, true
                end
                if dir == path then
                    entries = entries + 1
                end
                local full = dir .. "/" .. name
                if kind == "directory" then
                    stack[#stack + 1] = full
                else
                    local st = uv.fs_lstat(full)
                    bytes = bytes + ((st and st.size) or 0)
                end
            end
        end
    end
    return entries, bytes, false
end

--- Everything known about the entry under the cursor — the neo-tree `i`. A read-only popup (the canonical
--- `lvim-ui.info`), so it closes with `q` and never becomes another thing to manage.
local function action_info()
    local node = cur_node()
    if not node then
        return
    end
    local st = uv.fs_lstat(node.path)
    if not st then
        vim.notify("lvim-files: cannot stat " .. node.path, vim.log.levels.ERROR)
        return
    end
    local when = function(sec)
        return sec and os.date("%Y-%m-%d %H:%M:%S", sec) or "-"
    end
    -- Each row is a KEY box + a VALUE, and the value's colour says what KIND of fact it is (a path, a size, a
    -- permission, a time) — so the popup can be READ at a glance instead of parsed label by label.
    local lines, hls = {}, {}
    --- One info row: a KEY box and its VALUE, both in the row's own accent (`config.colors.info.accents`) —
    --- the value as text, the key as a wash of the same colour.
    ---@param k string     the label
    ---@param v string     the value
    ---@param kind string  the row's accent key ("name" | "path" | "size" | …)
    local function row(k, v, kind)
        local label = ("  %-11s"):format(k .. ":")
        local text = label .. " " .. v
        local r = #lines -- 0-based row for the highlight spans
        local name = kind:sub(1, 1):upper() .. kind:sub(2)
        lines[#lines + 1] = text
        hls[#hls + 1] = { r, 2, #label, "LvimFilesInfoKey" .. name } -- the key box (skip the 2-space lead)
        hls[#hls + 1] = { r, #label + 1, #text, "LvimFilesInfo" .. name }
    end

    local kind = st.type
    if st.type == "link" then
        local target = uv.fs_readlink(node.path)
        local real = uv.fs_stat(node.path) -- follows the link
        kind = ("link → %s%s"):format(target or "?", real and "" or "  (broken)")
    end

    lines[#lines + 1] = ""
    row("Name", node.name, "name")
    row("Path", vim.fn.fnamemodify(node.path, ":~"), "path")
    row("Type", kind, "type")
    if st.type == "directory" then
        -- Bounded walk: a directory's SIZE is its contents, but nothing may make this popup slow.
        local entries, bytes, truncated = dir_stats(node.path, 20000)
        row("Entries", tostring(entries), "size")
        row("Size", human_size(bytes) .. (truncated and "  (over 20k entries — partial)" or ""), "size")
    else
        row("Size", ("%s  (%d bytes)"):format(human_size(st.size), st.size), "size")
    end
    row("Perms", ("%s  (%04o)"):format(perm_string(st.mode), st.mode % 4096), "perms")
    row("Owner", ("uid %d / gid %d"):format(st.uid, st.gid), "owner")
    lines[#lines + 1] = ""
    row("Modified", when(st.mtime and st.mtime.sec), "time")
    row("Accessed", when(st.atime and st.atime.sec), "time")
    row("Changed", when(st.ctime and st.ctime.sec), "time")
    -- What the tree already knows about it, so the popup answers the same question the row's badge hints at.
    local gs = git.status(node.path)
    if gs and gs ~= "" then
        lines[#lines + 1] = ""
        row("Git", tostring(gs), "git")
    end
    if git.is_ignored(node.path) then
        row("Git", "ignored", "git")
    end
    lines[#lines + 1] = ""

    lvim_ui.info(lines, {
        title = { icon = config.icons.info or "", text = "Info" },
        title_pos = "center",
        highlights = hls,
    })
end

--- Create a file (or, with a trailing "/", a directory) under the target directory.
local function action_add()
    local dir = target_dir()
    text_input({
        title = "New in " .. vim.fn.pathshorten(vim.fn.fnamemodify(dir, ":~")) .. "  (…/ = directory)",
        callback = function(confirmed, value)
            if not confirmed or value == "" then
                return
            end
            local is_dir = value:sub(-1) == "/"
            local ok, err = ops.create(model.join(dir, (value:gsub("/+$", ""))), is_dir)
            if not ok then
                vim.notify("lvim-files: " .. (err or "create failed"), vim.log.levels.ERROR)
            end
            refresh_dir(dir)
        end,
    })
end

--- Rename the node under the cursor (in place; moves are `cut` + `paste`).
local function action_rename()
    local node = cur_node()
    if not node then
        return
    end
    local dir = node.parent and node.parent.path or vim.fs.dirname(node.path)
    text_input({
        title = "Rename " .. node.name,
        default = node.name,
        callback = function(confirmed, value)
            if not confirmed or value == "" or value == node.name then
                return
            end
            local ok, err = ops.rename(node.path, model.join(dir, value))
            if not ok then
                vim.notify("lvim-files: " .. (err or "rename failed"), vim.log.levels.ERROR)
            end
            refresh_dir(dir)
        end,
    })
end

--- Delete the node under the cursor (trash-aware confirm wording).
local function action_delete()
    local node = cur_node()
    if not node then
        return
    end
    local verb = ops.uses_trash() and "Trash" or "Delete"
    lvim_ui.confirm({
        title = verb .. " " .. node.name .. "?",
        default_no = true,
        callback = function(yes)
            if not yes then
                return
            end
            local dir = node.parent and node.parent.path or vim.fs.dirname(node.path)
            local ok, err = ops.delete(node.path)
            if not ok then
                vim.notify("lvim-files: " .. (err or "delete failed"), vim.log.levels.ERROR)
            end
            refresh_dir(dir)
        end,
    })
end

--- The nodes a copy/cut acts on: the VISUAL selection when there is one (that is what a selection MEANS),
--- else the single node under the cursor. Called from both the normal-mode key and the visual-mode one, so
--- `c`/`x` do the obvious thing in either — no separate "mark" mode to learn.
---@param visual boolean  invoked from a visual-mode mapping (read the selected line range)
---@return LvimFilesNode[]
local function nodes_for_action(visual)
    if not visual then
        local node = cur_node()
        return node and { node } or {}
    end
    -- The visual range: `v` marks are only written when visual mode ENDS, so read the LIVE selection —
    -- the cursor and the anchor (`v`) — which is what a `x`-mode mapping sees while the selection is up.
    local a = vim.fn.line(".")
    local b = vim.fn.line("v")
    if b < a then
        a, b = b, a
    end
    local out, seen = {}, {}
    for line = a, b do
        local ui = state.panel and state.panel.node_at(line)
        local node = ui and ui.data or nil
        if node and not seen[node.path] then
            seen[node.path] = true
            out[#out + 1] = node
        end
    end
    return out
end

--- Put the acted-on nodes on the clipboard (copy or cut).
---@param mode "copy"|"cut"
---@param visual boolean?
local function action_mark(mode, visual)
    local nodes = nodes_for_action(visual == true)
    if #nodes == 0 then
        return
    end
    local items = {}
    for _, n in ipairs(nodes) do
        items[#items + 1] = { path = n.path, name = n.name }
    end
    state.clipboard = { mode = mode, items = items }
    if visual then
        -- Leave visual mode: the selection has been consumed, and staying in it would let the next key
        -- (a `p`) act on a range the user no longer sees as live.
        vim.cmd("normal! \27")
    end
    local verb = mode == "copy" and "copied" or "cut"
    vim.notify(("lvim-files: %d %s"):format(#items, verb), vim.log.levels.INFO)
    do_render()
end

--- A name that does not collide in `dir`: "a.txt" → "a (copy).txt" → "a (copy 2).txt". The suffix goes
--- BEFORE the extension, so the file keeps its type (and its icon, and its `ft`).
---@param dir string
---@param name string
---@return string
local function free_name(dir, name)
    if not ops.exists(model.join(dir, name)) then
        return name
    end
    local stem, ext = name:match("^(.*)(%.[^.]+)$")
    if not stem or stem == "" then
        stem, ext = name, ""
    end
    for i = 1, 99 do
        local suffix = i == 1 and " (copy)" or (" (copy " .. i .. ")")
        local candidate = stem .. suffix .. ext
        if not ops.exists(model.join(dir, candidate)) then
            return candidate
        end
    end
    return stem .. " (copy " .. os.time() .. ")" .. ext
end

--- Paste EVERY clipboard entry into the directory under the cursor, one at a time — because a CONFLICT has
--- to be asked about, and asking is async. A name that already exists is never an error and never silently
--- overwritten: it offers a free name (pre-filled, editable), an explicit overwrite, or a skip — with an
--- "…for all" answer so a ten-file paste is not ten questions.
local function action_paste()
    local clip = state.clipboard
    if not clip or #clip.items == 0 then
        vim.notify("lvim-files: nothing to paste.", vim.log.levels.INFO)
        return
    end
    local dir = target_dir()
    local items = vim.deepcopy(clip.items)
    local mode = clip.mode
    local done, skipped, failed = 0, 0, {}
    local dirty = { [dir] = true }
    local all -- "overwrite" | "skip" — an answer the user chose to apply to every remaining conflict

    local finish, step

    --- Perform ONE entry into `name` (already conflict-resolved), then continue.
    ---@param it { path: string, name: string }
    ---@param i integer
    ---@param name string
    ---@param overwrite boolean
    local function place(it, i, name, overwrite)
        local dest = model.join(dir, name)
        if overwrite and ops.exists(dest) then
            local ok_del, err_del = ops.delete(dest)
            if not ok_del then
                failed[#failed + 1] = ("%s (%s)"):format(it.name, err_del or "cannot replace")
                return step(i + 1)
            end
        end
        local ok, err
        if mode == "copy" then
            ok, err = ops.copy(it.path, dest)
        else
            ok, err = ops.rename(it.path, dest)
        end
        if ok then
            done = done + 1
            dirty[vim.fs.dirname(it.path)] = true
        else
            failed[#failed + 1] = ("%s (%s)"):format(it.name, err or "failed")
        end
        step(i + 1)
    end

    --- Ask what to do about `it` colliding in `dir`.
    ---@param it { path: string, name: string }
    ---@param i integer
    local function ask(it, i)
        local suggestion = free_name(dir, it.name)
        local more = #items - i > 0
        local choices = {
            { label = "Keep both  →  " .. suggestion, id = "rename" },
            { label = "Overwrite", id = "overwrite" },
            { label = "Skip", id = "skip" },
        }
        if more then
            choices[#choices + 1] = { label = "Overwrite all", id = "overwrite_all" }
            choices[#choices + 1] = { label = "Skip all", id = "skip_all" }
        end
        lvim_ui.select({
            title = it.name .. " already exists here",
            items = choices,
            callback = function(confirmed, idx)
                if not confirmed then
                    skipped = skipped + (#items - i + 1) -- cancelling the dialog cancels the whole paste
                    return finish()
                end
                local id = choices[idx].id
                if id == "skip" then
                    skipped = skipped + 1
                    return step(i + 1)
                elseif id == "skip_all" then
                    all = "skip"
                    skipped = skipped + 1
                    return step(i + 1)
                elseif id == "overwrite" then
                    return place(it, i, it.name, true)
                elseif id == "overwrite_all" then
                    all = "overwrite"
                    return place(it, i, it.name, true)
                end
                -- Keep both: the suggested name, pre-filled and editable — the user may want their own.
                text_input({
                    title = "Paste as",
                    default = suggestion,
                    callback = function(ok, value)
                        value = vim.trim(value or "")
                        if not ok or value == "" then
                            skipped = skipped + 1
                            return step(i + 1)
                        end
                        place(it, i, value, false)
                    end,
                })
            end,
        })
    end

    step = function(i)
        local it = items[i]
        if not it then
            return finish()
        end
        local dest = model.join(dir, it.name)
        if not ops.exists(dest) then
            return place(it, i, it.name, false)
        end
        if all == "skip" then
            skipped = skipped + 1
            return step(i + 1)
        elseif all == "overwrite" then
            return place(it, i, it.name, true)
        end
        ask(it, i)
    end

    finish = function()
        -- A CUT is consumed by the paste (the entries moved); a COPY stays on the clipboard, so the same
        -- selection can be dropped into several directories.
        if mode == "cut" then
            state.clipboard = nil
        end
        for d in pairs(dirty) do
            refresh_dir(d)
        end
        local parts = { ("pasted %d"):format(done) }
        if skipped > 0 then
            parts[#parts + 1] = ("skipped %d"):format(skipped)
        end
        if #failed > 0 then
            parts[#parts + 1] = ("failed %d — %s"):format(#failed, table.concat(failed, ", "))
        end
        vim.notify(
            "lvim-files: " .. table.concat(parts, ", "),
            #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
        )
    end

    step(1)
end

--- Yank the node's absolute path to + and the unnamed register.
local function action_copy_path()
    local node = cur_node()
    if not node then
        return
    end
    vim.fn.setreg("+", node.path)
    vim.fn.setreg('"', node.path)
    vim.notify("lvim-files: " .. node.path, vim.log.levels.INFO)
end

local set_root -- forward decl

--- Re-root one directory up.
local function action_root_up()
    local parent = vim.fs.dirname(state.root.path)
    if parent and parent ~= state.root.path then
        state.panel.expand(state.root.path) -- keep the old root open under the new one
        set_root(parent)
    end
end

--- Re-root at the current working directory.
local function action_root_cwd()
    set_root(vim.fn.getcwd())
end

--- Expand every ancestor of `path`, then land the cursor on its row.
---@param path string
local function reveal(path)
    path = model.normalize(path)
    local root = state.root
    if not root then
        return
    end
    local prefix = root.path == "/" and "/" or (root.path .. "/")
    if path ~= root.path and path:sub(1, #prefix) ~= prefix then
        return
    end
    local comps = {}
    for comp in path:sub(#prefix + 1):gmatch("[^/]+") do
        comps[#comps + 1] = comp
    end
    ---@param node LvimFilesNode
    ---@param i integer
    local function step(node, i)
        if not (M.is_open() and state.panel) then
            return -- the async load chain outlived the panel
        end
        if i > #comps then
            collapse_others(path) -- keep only the revealed file's branch open (auto_collapse)
            do_render()
            state.panel.focus(path)
            return
        end
        model.load(node, function()
            local child
            for _, ch in ipairs(node.children or {}) do
                if ch.name == comps[i] then
                    child = ch
                    break
                end
            end
            if not child then
                do_render()
                return
            end
            if model.is_dir(child) and i < #comps then
                state.panel.expand(child.path) -- on_expand → watch (+ load, satisfied by this chain)
            end
            step(child, i + 1)
        end)
    end
    step(root, 1)
end

--- Fuzzy-jump within the loaded tree (delegates to lvim-picker over the loaded entries).
local function action_find()
    local ok, picker = pcall(require, "lvim-picker")
    if not ok then
        vim.notify("lvim-files: lvim-picker is not installed.", vim.log.levels.WARN)
        return
    end
    local items = {}
    local base = #state.root.path + 2
    ---@param node LvimFilesNode
    local function collect(node)
        for _, ch in ipairs(node.children or {}) do
            if visible(ch) then
                items[#items + 1] = { text = ch.path:sub(base), path = ch.path }
                if ch.loaded then
                    collect(ch)
                end
            end
        end
    end
    collect(state.root)
    picker.open({
        title = "Files tree",
        items = items,
        on_confirm = function(item)
            if item and item.path then
                reveal(item.path)
            end
        end,
    })
end

--- Rescan every loaded directory (and git) — the manual refresh.
local function action_refresh()
    ---@param node LvimFilesNode
    local function walk(node)
        if node.loaded then
            model.load(node, schedule_render, true)
            for _, ch in ipairs(node.children or {}) do
                walk(ch)
            end
        end
    end
    walk(state.root)
    git.refresh(state.root.path)
end

--- Open the EDIT view on the directory under the cursor (root on a file / the header).
local function action_edit_mode()
    require("lvim-files.edit").open(target_dir())
end

-- ── help window (the canonical cheatsheet) ────────────────────────────────────

-- Action name → label, in display order.
local HELP = {
    { "open", "expand directory / open file" },
    { "close_node", "collapse / to parent" },
    { "open_pick", "open in picked window" },
    { "open_vsplit", "open in vertical split" },
    { "open_split", "open in horizontal split" },
    { "open_tab", "open in new tab" },
    { "add", "create (…/ = directory)" },
    { "rename", "rename" },
    { "delete", "delete (trash-aware)" },
    { "copy", "mark for copy" },
    { "cut", "mark for cut" },
    { "paste", "paste into directory" },
    { "copy_path", "yank absolute path" },
    { "root_up", "root one directory up" },
    { "root_cwd", "root at cwd" },
    { "find", "fuzzy jump in the tree" },
    { "toggle_dotfiles", "toggle dotfiles" },
    { "toggle_gitignore", "toggle git-ignored" },
    { "refresh", "rescan tree + git" },
    { "edit_mode", "edit view on directory" },
    { "help", "this help" },
    { "close", "close the panel" },
}

--- The keymap cheatsheet — the shared `lvim-ui.help` component (the rows, the striping, the colours and the
--- window all live there; this only supplies the plugin's LIVE keys).
function show_help()
    local keys = cfg().keys
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = keys[e[1]]
        if lhs then
            lhs = type(lhs) == "table" and table.concat(lhs, " / ") or lhs
            items[#items + 1] = { lhs, e[2] }
        end
    end
    local close = { "<Esc>" }
    local ck = keys.close
    if type(ck) == "table" then
        for _, k in ipairs(ck) do
            close[#close + 1] = k
        end
    elseif ck then
        close[#close + 1] = ck
    end
    if keys.help then
        close[#close + 1] = key_label(keys.help)
    end
    lvim_ui.help({ title = "Files keymaps", items = items, close_keys = close })
end

-- ── keymaps / autocmds ────────────────────────────────────────────────────────

--- Bind the panel's config keymaps (the tree's `on_keys` hook — bound AFTER the tree's canonical
--- `l`/`<CR>`/`h`, so a config key on the same lhs overrides the default). Mouse is the shared tree
--- canon: a click selects + activates the row (open the file / toggle the directory), a click on the
--- fold chevron / a double-click toggles the fold.
---@param map fun(lhs: string|string[], fn: fun())
local function set_keys(map)
    local actions = {
        open = action_open,
        close_node = function()
            state.panel.collapse_or_parent()
        end,
        open_pick = action_open_pick,
        open_vsplit = function()
            open_current_as("vsplit")
        end,
        open_split = function()
            open_current_as("split")
        end,
        open_tab = function()
            open_current_as("tab")
        end,
        add = action_add,
        rename = action_rename,
        delete = action_delete,
        copy = function()
            action_mark("copy")
        end,
        cut = function()
            action_mark("cut")
        end,
        paste = action_paste,
        copy_path = action_copy_path,
        root_up = action_root_up,
        root_cwd = action_root_cwd,
        find = action_find,
        toggle_dotfiles = toggle_dotfiles,
        toggle_gitignore = toggle_gitignore,
        refresh = action_refresh,
        edit_mode = action_edit_mode,
        info = action_info,
        help = show_help,
        close = M.close,
    }
    for action, lhs in pairs(cfg().keys or {}) do
        local fn = actions[action]
        if fn then
            map(lhs, fn)
        end
    end

    -- copy / cut in VISUAL mode: select the rows, press the key, then `p` in the target directory. That is the
    -- whole point of a selection, and it is what a file tree is expected to do — the edit buffer is for a real
    -- refactor, not for moving two files. The tree's own `map` is normal-mode only (it owns j/k/<CR>/…), so
    -- these are bound straight on the panel buffer.
    --
    -- `copy_path` (`y`) is included ON PURPOSE: with a SELECTION up, `y` universally means "copy THESE" — that
    -- is the neo-tree reflex, and letting it fall through to Vim's own line-yank silently copied the rendered
    -- TEXT of the rows while the file clipboard kept whatever was in it before, so a later `p` pasted the wrong
    -- thing. In NORMAL mode `y` keeps its meaning (yank the path to the registers) — there is no selection
    -- there to copy.
    if state.buf and api.nvim_buf_is_valid(state.buf) then
        local keys = cfg().keys or {}
        for action, mode in pairs({ copy = "copy", copy_path = "copy", cut = "cut" }) do
            for _, lhs in ipairs(type(keys[action]) == "table" and keys[action] or { keys[action] }) do
                if type(lhs) == "string" and lhs ~= "" then
                    vim.keymap.set("x", lhs, function()
                        action_mark(mode, true)
                    end, {
                        buffer = state.buf,
                        nowait = true,
                        silent = true,
                        desc = "lvim-files: " .. mode .. " the selected entries",
                    })
                end
            end
        end
    end
end

local function setup_autocmds()
    state.augroup = api.nvim_create_augroup("LvimFilesPanel", { clear = true })
    -- close_if_last (opt-in): when some other window closes and the tree would be left ALONE in the tab,
    -- close it too so it never blocks a quit. Deferred so the closing window is already gone; floats are
    -- ignored. In the last tab the tree is the last real window (which can't be `nvim_win_close`d) so we
    -- `:quit` (ending nvim); with other tabs open, closing the tree's window collapses this empty tab.
    api.nvim_create_autocmd("WinClosed", {
        group = state.augroup,
        callback = function(ev)
            if not (cfg().close_if_last and M.is_open() and state.win) then
                return
            end
            if tonumber(ev.match) == state.win then
                return -- the tree's own window is closing (teardown handles it)
            end
            vim.schedule(function()
                if not (M.is_open() and state.win and is_valid_win(state.win)) then
                    return
                end
                for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
                    if w ~= state.win and api.nvim_win_get_config(w).relative == "" then
                        return -- another real window remains → keep the tree
                    end
                end
                if #api.nvim_list_tabpages() > 1 then
                    M.close()
                else
                    vim.cmd("quit")
                end
            end)
        end,
    })
    -- Follow the current file: whenever focus lands on a real file buffer OUTSIDE the tree/floats, reveal
    -- + select it in the tree. `reveal` only moves the PANEL cursor, so it never fights the editor; the
    -- `followed` guard skips redundant reveals when the same file is re-entered.
    api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        group = state.augroup,
        callback = function()
            if not (M.is_open() and cfg().follow ~= false and state.root) then
                return
            end
            local cw = api.nvim_get_current_win()
            if cw == state.win or api.nvim_win_get_config(cw).relative ~= "" then
                return
            end
            local buf = api.nvim_win_get_buf(cw)
            if vim.bo[buf].buftype ~= "" then
                return
            end
            local name = api.nvim_buf_get_name(buf)
            if name == "" then
                return
            end
            name = model.normalize(name)
            if name == state.followed then
                return
            end
            state.followed = name
            reveal(name)
        end,
    })
    -- Debounced diagnostics repaint (DiagnosticChanged fires in bursts while typing).
    api.nvim_create_autocmd("DiagnosticChanged", {
        group = state.augroup,
        callback = function()
            if not (state.diag_timer and M.is_open()) then
                return
            end
            state.diag_timer:stop()
            state.diag_timer:start(
                200,
                0,
                vim.schedule_wrap(function()
                    if M.is_open() and state.root then
                        state.diag = render.diagnostics(state.root.path)
                        do_render()
                    end
                end)
            )
        end,
    })
    -- A write anywhere refreshes git for that file's repo.
    api.nvim_create_autocmd("BufWritePost", {
        group = state.augroup,
        callback = function(ev)
            if M.is_open() then
                local name = api.nvim_buf_get_name(ev.buf)
                if name ~= "" then
                    git.refresh(name)
                end
            end
        end,
    })
    -- A filesystem op anywhere (the edit view's apply, another consumer) fires `User LvimFiles<Op>`
    -- with `{ path?, from?, to? }` — rescan the affected directories so the tree reflects it even though
    -- the change did not come from the panel's own keymaps. The parent of each path is reloaded from
    -- disk (falling back to the root); refresh_dir is a no-op for dirs not currently in the tree.
    api.nvim_create_autocmd("User", {
        group = state.augroup,
        pattern = "LvimFiles*",
        callback = function(ev)
            -- Deferred: the event fires from INSIDE apply_ops (mid loop), before it releases the edit
            -- view's shared nodes and resets state — rescanning then races that teardown. Scheduling runs
            -- the refresh once apply has fully settled, so the reload always sees the final model state.
            local data = type(ev.data) == "table" and ev.data or {}
            vim.schedule(function()
                if not (M.is_open() and state.root) then
                    return
                end
                -- Iterate the payload keys EXPLICITLY: `{ data.path, data.from, data.to }` has a nil hole
                -- for ops that omit one (a rename carries from/to but no path), and `ipairs` stops at the
                -- first nil — which silently skipped every rename/move to the root fallback (refreshing the
                -- wrong directory for a rename inside an expanded SUBdirectory).
                local seen = {}
                for _, key in ipairs({ "path", "from", "to" }) do
                    local p = data[key]
                    if type(p) == "string" and p ~= "" then
                        local parent = vim.fs.dirname(p)
                        if parent and not seen[parent] then
                            seen[parent] = true
                            refresh_dir(parent)
                        end
                    end
                end
                if not next(seen) then
                    refresh_dir(state.root.path)
                end
            end)
        end,
    })
    -- Track the last real editor window so `open` lands where the user was.
    api.nvim_create_autocmd("WinEnter", {
        group = state.augroup,
        callback = function()
            local w = api.nvim_get_current_win()
            if w ~= state.win and api.nvim_win_get_config(w).relative == "" then
                local b = api.nvim_win_get_buf(w)
                if vim.bo[b].buftype == "" then
                    state.opener = w
                end
            end
        end,
    })
    -- (The header-row cursor clamp and the resize re-render are the shared tree's / the surface's job
    -- now — the tree keeps the cursor off its `header` rows, the native split re-renders on WinResized.)
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

--- (Re-)root the tree at `path` — releases the old root's subtree and rescans.
---@param path string
set_root = function(path)
    path = model.normalize(path)
    for _, node in pairs(state.watched) do
        model.unwatch(node)
    end
    state.watched = {}
    if state.root then
        model.release(state.root)
    end
    state.root = model.root(path)
    watch(state.root)
    state.diag = render.diagnostics(path)
    git.refresh(path)
    model.load(state.root, schedule_render, true)
    do_render()
end

--- Open the panel (a native side split). Keeps focus in the editor unless `enter`.
---@param enter? boolean
---@param path? string   root directory (default: the cwd, or the current tree root)
function M.open(enter, path)
    if M.is_open() then
        if path then
            set_root(path)
        end
        if enter then
            api.nvim_set_current_win(state.win)
        end
        return
    end
    if not state.seeded then
        state.seeded = true
        state.show_dotfiles = config.filters.dotfiles ~= false
        state.show_gitignore = config.filters.gitignore ~= false
    end
    local w = api.nvim_get_current_win()
    local seed_file
    if api.nvim_win_get_config(w).relative == "" and vim.bo[api.nvim_win_get_buf(w)].buftype == "" then
        state.opener = w
        local name = api.nvim_buf_get_name(api.nvim_win_get_buf(w))
        if name ~= "" then
            seed_file = model.normalize(name) -- the file we open FROM, to reveal once the tree is up
        end
    end

    local pc = cfg()
    -- The SHARED lvim-ui.tree is the content layer: it owns fold state, guides/markers, badges, the
    -- scrollbar, the header clamp and the canonical keys + mouse; this module feeds it model nodes
    -- (the lazy `to_nodes` factory) and binds the file actions on top.
    state.panel = lvim_ui.tree({
        default_expanded = false, -- directories start collapsed; the expand set is the user's
        connectors = false, -- plain rows (no ├/└) — the file-tree look
        elide_guides = false, -- a solid │ per ancestor level
        -- Content padding + scrollbar come from the LIVE config; the tree reserves one more right column for the
        -- thumb whenever the bar is actually shown, so the bar never eats into the padding.
        padding = pc.padding,
        scrollbar = pc.scrollbar == true,
        icons = {
            fold_open = config.icons.fold_open,
            fold_closed = config.icons.fold_closed,
            guide = config.icons.guide,
        },
        hl = {
            guide = "LvimFilesGuide",
            fold = "LvimFilesFold",
            empty = "LvimFilesEmpty",
        },
        empty = "  (empty)",
        -- The root-path band: the tree's header rows (cursor kept off them by the primitive).
        header = function(width)
            return { " " .. config.icons.dir_open .. " " .. root_label(width) }, { { 0, 0, -1, "LvimFilesRoot" } }
        end,
        filetype = "lvim-files", -- register this in the user's cursor `panel_ft` list
        cursorline = true,
        double_click = config.panel.mouse_open == "double", -- a single click then only selects; double click opens/expands

        size = function()
            local width = pc.width or 34
            local px = (width <= 1) and math.floor(vim.o.columns * width) or math.floor(width)
            return math.max(20, px), 1
        end,
        -- The lazy top level: re-run per render so every repaint re-decorates live (git/diag badges).
        root = function()
            return state.root and to_nodes(state.root) or {}
        end,
        -- Activation (canonical <CR>/l fallback + the mouse click): open a file / toggle a directory.
        on_activate = function(ui)
            if model.is_dir(ui.data) then
                state.panel.toggle(ui.data.path)
            else
                open_file(ui.data)
            end
        end,
        -- Every expansion path (key, mouse chevron, reveal) funnels here: watch the directory, kick its
        -- scan, and — with `auto_collapse` — keep only this branch open.
        on_expand = function(ui)
            watch(ui.data)
            ensure_loaded(ui.data)
            collapse_others(ui.data.path)
        end,
        on_collapse = function(ui)
            unwatch(ui.data)
        end,
        on_keys = function(map, pan)
            state.buf, state.win = pan.buf, pan.win
            set_keys(map)
        end,
        -- Live footer counts after every repaint: what the filters cover (over every LOADED entry,
        -- unfiltered) — pushed into the surface's bottom-pinned filter bar.
        on_render = function()
            if not (state.root and state.surface and state.surface.set_footer) then
                return
            end
            local counts = { dot = 0, ign = 0 }
            ---@param node LvimFilesNode
            local function count_walk(node)
                for _, ch in ipairs(node.children or {}) do
                    if ch.name:sub(1, 1) == "." then
                        counts.dot = counts.dot + 1
                    end
                    if git.is_ignored(ch.path) then
                        counts.ign = counts.ign + 1
                    end
                    if ch.loaded then
                        count_walk(ch)
                    end
                end
            end
            count_walk(state.root)
            state.surface.set_footer({ bars = { { items = filter_items(counts), align = "center" } } })
        end,
        on_close = function()
            for _, node in pairs(state.watched) do
                model.unwatch(node)
            end
            state.watched = {}
            if state.root then
                model.release(state.root)
            end
            if state.diag_timer then
                state.diag_timer:stop()
                if not state.diag_timer:is_closing() then
                    state.diag_timer:close()
                end
                state.diag_timer = nil
            end
            if state.augroup then
                pcall(api.nvim_del_augroup_by_id, state.augroup)
                state.augroup = nil
            end
            for _, unsub in ipairs(state.unsub) do
                pcall(unsub)
            end
            state.unsub = {}
            state.win, state.buf, state.root, state.panel, state.surface = nil, nil, nil, nil, nil
        end,
    })

    state.surface = surface.open({
        mode = "split",
        native = true,
        dock = pc.side == "right" and "right" or "left",
        enter = enter == true,
        persistent = true,
        normal_hl = "NormalSB",
        title = (pc.title ~= false and pc.title ~= "") and pc.title or nil,
        size = { width = { fixed = pc.width or 34 } },
        content = { blocks = { { id = "tree", provider = state.panel.provider } } },
        -- The dot / git filter toggles ride the surface's native-split FOOTER (pinned to the panel
        -- bottom); the tree's `on_render` refreshes it live via state.surface.set_footer with the
        -- real counts.
        footer = { bars = { { items = filter_items({ dot = 0, ign = 0 }), align = "center" } } },
        close_keys = {},
    })
    if not state.diag_timer then
        state.diag_timer = uv.new_timer()
    end
    setup_autocmds()
    state.unsub[#state.unsub + 1] = model.on_change(function()
        if M.is_open() then
            schedule_render()
        end
    end)
    state.unsub[#state.unsub + 1] = git.on_change(function()
        if M.is_open() then
            schedule_render()
        end
    end)
    set_root(path or vim.fn.getcwd())
    -- Land on the file the tree was opened FROM (once the root scan is up), so opening the tree reveals
    -- where you are — the on-open counterpart to `follow`.
    if seed_file and cfg().follow ~= false then
        state.followed = seed_file
        vim.schedule(function()
            reveal(seed_file)
        end)
    end
end

--- Close the panel (frame teardown fires the provider on_close). Idempotent.
function M.close()
    if not state.surface then
        return
    end
    local f = state.surface
    state.surface = nil
    if f then
        pcall(f.close)
    end
end

--- Toggle the panel. Opening focuses the tree unless `focus_on_open = false`.
---@param path? string
function M.toggle(path)
    if M.is_open() then
        M.close()
    else
        M.open(cfg().focus_on_open ~= false, path)
    end
end

--- Focus the panel (opening it if needed).
function M.focus()
    if not M.is_open() then
        M.open(true)
    end
    if is_valid_win(state.win) then
        api.nvim_set_current_win(state.win)
    end
end

--- Reveal (expand to + select) an absolute path in the tree.
---@param path string
function M.reveal(path)
    if M.is_open() then
        reveal(path)
    end
end

return M
