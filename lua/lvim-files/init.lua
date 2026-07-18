-- lvim-files: one file manager, two presentations over ONE fs model / ops engine /
-- decoration pipeline:
--
--   · the TREE PANEL — a persistent native side split (the neo-tree role): lazy async tree,
--     lvim-icons entries, git + diagnostics badges, filter bands, create/rename/delete/
--     copy/cut/paste, open-in-picked-window (lvim-winpick), fuzzy tree jump (lvim-picker);
--   · the EDIT VIEW — a directory as a modifiable buffer in a centred float (the
--     mini.files / fyler role): editing lines IS the operation — the buffer is diffed by
--     per-line extmark identity into an ordered, confirmed op list.
--
-- Every fs change funnels through fs/ops.lua: LSP `workspace/willRenameFiles` first, open
-- buffers re-pointed, `User LvimFiles*` autocmds fired, deletes trash-aware. setup() merges
-- user options into the live config and registers the `:LvimFiles` command (and, opt-in,
-- the netrw directory hijack that opens directories in the edit view).
--
---@module "lvim-files"

local config = require("lvim-files.config")
local highlights = require("lvim-files.highlights")
local uhl = require("lvim-utils.highlight")
local utils = require("lvim-utils.utils")

local M = {}

---@type boolean  one-time registration guard (command / autocmds / highlight bind)
local registered = false

-- :LvimFiles subcommands (also the completion source).
---@type string[]
local SUBCOMMANDS = { "panel", "focus", "close", "edit", "toggle" }

--- Dispatch `:LvimFiles [subcommand] [path]`.
---@param cmd table  the nvim_create_user_command callback arg
local function dispatch(cmd)
    local sub = cmd.fargs[1]
    local path = cmd.fargs[2]
    local panel = require("lvim-files.panel")
    if sub == nil or sub == "panel" or sub == "toggle" then
        panel.toggle(path)
    elseif sub == "focus" then
        panel.focus()
    elseif sub == "close" then
        panel.close()
        require("lvim-files.edit").close(true)
    elseif sub == "edit" then
        require("lvim-files.edit").open(path)
    else
        vim.notify("lvim-files: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
end

--- Command completion: subcommands first, then directories for the path argument.
---@param arglead string
---@param cmdline string
---@return string[]
local function complete(arglead, cmdline)
    local args = vim.split(vim.trim(cmdline), "%s+")
    if #args <= 1 or (#args == 2 and arglead ~= "") then
        return vim.tbl_filter(function(s)
            return s:find(arglead, 1, true) == 1
        end, SUBCOMMANDS)
    end
    return vim.fn.getcompletion(arglead, "dir")
end

--- Replace netrw for DIRECTORY buffers with the edit view (opt-in via `hijack_netrw`).
local function hijack_netrw()
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1
    local group = vim.api.nvim_create_augroup("LvimFilesHijack", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(ev)
            local name = vim.api.nvim_buf_get_name(ev.buf)
            if name ~= "" and vim.fn.isdirectory(name) == 1 and vim.bo[ev.buf].buftype == "" then
                -- Swap the directory buffer out from under the window, then open the edit view.
                vim.bo[ev.buf].bufhidden = "wipe"
                local alt = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_win_set_buf(0, alt)
                vim.schedule(function()
                    require("lvim-files.edit").open(name)
                end)
            end
        end,
    })
end

--- Merge user options into the LIVE config (in place, via lvim-utils.utils.merge) and
--- register the command, the highlight factory and (opt-in) the netrw hijack.
---@param opts? LvimFilesConfig
function M.setup(opts)
    utils.merge(config, opts or {})
    if config.hijack_netrw then
        hijack_netrw()
    end
    if registered then
        return
    end
    registered = true
    uhl.bind(highlights.build)
    -- Self-register the tree panel's filetype for cursor hiding — a PERSISTENT side panel (hide the cursor
    -- ONLY while it is the current window). `cursor.register` extends the registry at runtime without
    -- rebuilding the autocmds, so installing lvim-files needs no entry in the central cursor config.
    pcall(function()
        require("lvim-utils.cursor").register({ panel_ft = { "lvim-files" } })
    end)
    -- Self-register a gx adapter so `gx` on a tree row resolves the entry's REAL path (with its dir
    -- context) instead of falling back to gx's proximity scan of the rendered row. Optional: pcall
    -- keeps lvim-common a soft dependency, and register_adapter is load-order-independent.
    pcall(function()
        require("lvim-common.gx").register_adapter({
            name = "lvim_files",
            ---@param ctx { filetype: string }
            detect = function(ctx)
                return ctx.filetype == "lvim-files"
            end,
            get = function()
                return M.entry_under_cursor()
            end,
        })
    end)
    vim.api.nvim_create_user_command("LvimFiles", dispatch, {
        nargs = "*",
        complete = complete,
        desc = "lvim-files: panel | focus | close | edit [dir]",
    })
end

--- Open the tree panel.
---@param enter? boolean  focus it
---@param path? string    root directory (default cwd)
function M.open(enter, path)
    require("lvim-files.panel").open(enter, path)
end

--- Close the tree panel.
function M.close()
    require("lvim-files.panel").close()
end

--- Toggle the tree panel.
---@param path? string
function M.toggle(path)
    require("lvim-files.panel").toggle(path)
end

--- Focus the tree panel (opening it if needed).
function M.focus()
    require("lvim-files.panel").focus()
end

--- Reveal an absolute path in the tree panel.
---@param path string
function M.reveal(path)
    require("lvim-files.panel").reveal(path)
end

--- Open the edit view on a directory.
---@param dir? string
function M.edit(dir)
    require("lvim-files.edit").open(dir)
end

--- The fs entry under the tree-panel cursor, as a `{ path, type }` descriptor (nil on the
--- header/empty rows or when the panel is closed). Public seam for external "open under cursor"
--- integrations — lvim-common's gx uses it via the self-registered `lvim_files` adapter.
---@return { path: string, type: "dir"|"file" }|nil
function M.entry_under_cursor()
    return require("lvim-files.panel").entry_under_cursor()
end

return M
