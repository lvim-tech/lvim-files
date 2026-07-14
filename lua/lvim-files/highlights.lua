-- lvim-files.highlights: every LvimFiles* group, derived from the live lvim-utils palette.
-- build() is a FACTORY (called per application) so each run reads the palette of the moment;
-- init.lua binds it through lvim-utils.highlight.bind, which re-applies on ColorScheme and on
-- palette sync. Tints follow the canon: a coloured block is its accent mtint-ed toward the bg
-- (op rows 0.2, the active op row 0.4 — the confirm panel's whole-row read).
--
---@module "lvim-files.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- Blend an accent toward the editor bg — the shared "mtint" convention.
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- Resolve an accent: a palette KEY ("blue") or a literal "#rrggbb".
---@param v string?
---@param fallback string
---@return string
local function col(v, fallback)
    v = v or fallback
    if v:sub(1, 1) == "#" then
        return v
    end
    return c[v] or c[fallback] or c.blue
end

--- The `i` info popup's groups, from `config.colors.info`: for every ROW KIND one pair —
--- `LvimFilesInfo<Kind>` (the VALUE: the accent as text) and `LvimFilesInfoKey<Kind>` (the KEY box: the same
--- accent washed onto the bg at `tint`). One accent per row, so a row reads as a single colour, and NO row
--- is left as plain fg — the popup is scanned by colour, not parsed label by label.
---@param out table<string, table>  the group map, filled in place
local function info_groups(out)
    local info = require("lvim-files.config").colors.info
    for kind, accent in pairs(info.accents) do
        local a = col(accent, "blue")
        local name = kind:sub(1, 1):upper() .. kind:sub(2)
        out["LvimFilesInfo" .. name] = { fg = a }
        out["LvimFilesInfoKey" .. name] = { fg = a, bg = mtint(a, info.tint), bold = true }
    end
end

--- The LvimFiles* groups from the live palette.
---@return table<string, table>
function M.build()
    local groups = {
        -- entry names — directories GREEN (a hidden `.dir` a dimmer green so it reads as secondary)
        LvimFilesDir = { fg = c.green, bold = true },
        LvimFilesDirHidden = { fg = hl.blend(c.green, c.bg, 0.55), bold = true },
        LvimFilesFile = { fg = c.fg },
        LvimFilesSymlink = { fg = c.cyan, italic = true },
        LvimFilesExec = { fg = c.green },
        LvimFilesCut = { fg = c.comment, strikethrough = true },

        -- The `i` info popup — built from `config.colors.info` (accents + one tint), never from literals:
        -- see `info_groups()` above. Each row is one accent: the value wears it as TEXT, its key box as a
        -- WASH of the same colour.
        -- tree chrome — the root header + fold carets track the directory green
        LvimFilesRoot = { fg = c.green, bg = mtint(c.green, 0.2), bold = true },
        LvimFilesGuide = { fg = hl.blend(c.fg_dark, c.bg, 0.6) },
        LvimFilesFold = { fg = c.green },
        LvimFilesEmpty = { fg = c.comment, italic = true },
        -- git badges
        LvimFilesGitAdded = { fg = c.green },
        LvimFilesGitModified = { fg = c.yellow },
        LvimFilesGitDeleted = { fg = c.red },
        LvimFilesGitRenamed = { fg = c.purple },
        LvimFilesGitUntracked = { fg = c.orange },
        LvimFilesGitIgnored = { fg = c.comment },
        LvimFilesGitConflict = { fg = c.red, bold = true },
        -- diagnostics badges
        LvimFilesDiagError = { fg = c.red },
        LvimFilesDiagWarn = { fg = c.yellow },
        LvimFilesDiagInfo = { fg = c.blue },
        LvimFilesDiagHint = { fg = c.cyan },
        -- the edit-view confirm panel op rows (0.2 body tint, 0.4 on the active row)
        LvimFilesOpAdd = { fg = c.green, bg = mtint(c.green, 0.2) },
        LvimFilesOpAddActive = { fg = c.green, bg = mtint(c.green, 0.4) },
        LvimFilesOpChange = { fg = c.yellow, bg = mtint(c.yellow, 0.2) },
        LvimFilesOpChangeActive = { fg = c.yellow, bg = mtint(c.yellow, 0.4) },
        LvimFilesOpDelete = { fg = c.red, bg = mtint(c.red, 0.2) },
        LvimFilesOpDeleteActive = { fg = c.red, bg = mtint(c.red, 0.4) },
        LvimFilesOpNote = { fg = c.red, bold = true, italic = true },
        -- the panel filter bar (4-state button boxes: dim / accent / cursor / soft block)
        LvimFilesFilterKey = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
        LvimFilesFilterOn = { fg = c.green, bold = true },
        LvimFilesFilterOff = { fg = hl.blend(c.green, c.bg, 0.6) },
    }
    info_groups(groups)
    return groups
end

return M
