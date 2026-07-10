-- lvim-files.render: the ONE decoration pipeline both presentations draw from — icon + name
-- highlight per node (through the lvim-utils icon facade, so lvim-icons wins when installed
-- but nothing hard-depends on it), git status badges, and the diagnostics map (per-path max
-- severity with ancestor propagation). The views own their layout; this module owns what an
-- entry LOOKS like.
--
---@module "lvim-files.render"

local config = require("lvim-files.config")
local git = require("lvim-files.fs.git")
local model = require("lvim-files.fs.model")
local iconlib = require("lvim-utils.icons")

local M = {}

--- The icon glyph + highlight group for a node. Directories/symlinks resolve through the
--- icon provider's KIND table; files by name. A provider that returns no group falls back
--- to the plugin's own name groups so the row is never unthemed.
---@param node LvimFilesNode
---@param expanded? boolean
---@return string glyph, string hl
function M.node_icon(node, expanded)
    local icons = config.icons
    local res
    if node.type == "directory" then
        -- Keep the icon provider's GLYPH but paint it with the LvimFiles directory colour (green, or a
        -- dimmer green for a hidden `.dir`) so folders read consistently on the theme, not the icon set's
        -- own (often light-blue) folder hue.
        local dir_hl = node.name:sub(1, 1) == "." and "LvimFilesDirHidden" or "LvimFilesDir"
        res = iconlib.get(node.name, { kind = expanded and "directory_open" or "directory" })
        local glyph = (res and res.glyph ~= "") and res.glyph or (expanded and icons.dir_open or icons.dir)
        return glyph, dir_hl
    elseif node.type == "link" then
        local kind = node.broken_link and "symlink_broken" or (node.link_dir and "symlink_dir" or "symlink")
        res = iconlib.get(node.name, { kind = kind })
        if not res or res.glyph == "" then
            return icons.symlink, "LvimFilesSymlink"
        end
        return res.glyph, (res.hl ~= "" and res.hl) or "LvimFilesSymlink"
    end
    res = iconlib.get(node.name)
    if not res or res.glyph == "" then
        return icons.file, "LvimFilesFile"
    end
    return res.glyph, (res.hl ~= "" and res.hl) or "LvimFilesFile"
end

--- The highlight group for a node's NAME text.
---@param node LvimFilesNode
---@return string
function M.name_hl(node)
    if model.is_dir(node) then
        return node.name:sub(1, 1) == "." and "LvimFilesDirHidden" or "LvimFilesDir"
    end
    if node.type == "link" then
        return "LvimFilesSymlink"
    end
    if node.executable then
        return "LvimFilesExec"
    end
    return "LvimFilesFile"
end

-- git status name → its badge highlight group.
---@type table<string, string>
local GIT_HL = {
    added = "LvimFilesGitAdded",
    modified = "LvimFilesGitModified",
    deleted = "LvimFilesGitDeleted",
    renamed = "LvimFilesGitRenamed",
    untracked = "LvimFilesGitUntracked",
    ignored = "LvimFilesGitIgnored",
    conflict = "LvimFilesGitConflict",
}

--- The git badge (glyph + group) for a path, or nil when it carries no status.
---@param path string
---@return string|nil glyph, string|nil hl
function M.git_badge(path)
    if config.git.enabled == false then
        return nil
    end
    local status = git.status(path)
    if not status then
        return nil
    end
    local glyph = config.icons.git[status]
    if not glyph then
        return nil
    end
    return glyph, GIT_HL[status] or "LvimFilesGitModified"
end

-- vim.diagnostic severity → { icon config key, badge group }.
---@type table<integer, { icon: string, hl: string }>
local DIAG = {
    [vim.diagnostic.severity.ERROR] = { icon = "error", hl = "LvimFilesDiagError" },
    [vim.diagnostic.severity.WARN] = { icon = "warn", hl = "LvimFilesDiagWarn" },
    [vim.diagnostic.severity.INFO] = { icon = "info", hl = "LvimFilesDiagInfo" },
    [vim.diagnostic.severity.HINT] = { icon = "hint", hl = "LvimFilesDiagHint" },
}

--- The diagnostics badge for a severity, or nil.
---@param severity integer|nil
---@return string|nil glyph, string|nil hl
function M.diag_badge(severity)
    local d = severity and DIAG[severity]
    if not d then
        return nil
    end
    return config.icons.diag[d.icon], d.hl
end

--- Per-path MAX diagnostic severity for every named buffer, propagated to ancestor
--- directories up to (and including) `root_path` — so a directory badges with the worst
--- diagnostic of any file inside it.
---@param root_path string
---@return table<string, integer>  path → vim.diagnostic.severity (lower = worse)
function M.diagnostics(root_path)
    ---@type table<string, integer>
    local map = {}
    if config.diagnostics == false then
        return map
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                local counts = vim.diagnostic.count(buf)
                local worst
                for sev = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.HINT do
                    if counts[sev] and counts[sev] > 0 then
                        worst = sev
                        break
                    end
                end
                if worst then
                    local path = model.normalize(name)
                    local p = path
                    while p and (#p >= #root_path) do
                        if not map[p] or map[p] > worst then
                            map[p] = worst
                        end
                        if p == root_path then
                            break
                        end
                        p = vim.fs.dirname(p)
                    end
                end
            end
        end
    end
    return map
end

--- The `icon name` text of an entry line in the EDIT view, plus its highlight spans
--- (byte-based, ready for extmarks).
---@param node LvimFilesNode
---@return string line, { [1]: integer, [2]: integer, [3]: string }[] spans
function M.edit_line(node)
    local glyph, icon_hl = M.node_icon(node, false)
    local line = glyph .. " " .. node.name
    local spans = {
        { 0, #glyph, icon_hl },
        { #glyph + 1, #line, M.name_hl(node) },
    }
    return line, spans
end

return M
