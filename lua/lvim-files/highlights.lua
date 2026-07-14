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

--- The LvimFiles* groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        -- entry names — directories GREEN (a hidden `.dir` a dimmer green so it reads as secondary)
        LvimFilesDir = { fg = c.green, bold = true },
        LvimFilesDirHidden = { fg = hl.blend(c.green, c.bg, 0.55), bold = true },
        LvimFilesFile = { fg = c.fg },
        LvimFilesSymlink = { fg = c.cyan, italic = true },
        LvimFilesExec = { fg = c.green },
        LvimFilesCut = { fg = c.comment, strikethrough = true },

        -- The `i` info popup: a KEY column (a tinted badge box, like every other key cell in the chrome) and
        -- a VALUE coloured by what it MEANS — a path is not a size is not a permission bit. The eye should be
        -- able to find "how big" or "who owns it" without reading the labels.
        LvimFilesInfoKey = { fg = c.blue, bg = mtint(c.blue, 0.2), bold = true },
        LvimFilesInfoName = { fg = c.fg, bold = true },
        LvimFilesInfoPath = { fg = c.yellow },
        LvimFilesInfoType = { fg = c.purple },
        LvimFilesInfoSize = { fg = c.green },
        LvimFilesInfoPerms = { fg = c.orange },
        LvimFilesInfoOwner = { fg = c.comment },
        LvimFilesInfoTime = { fg = c.cyan },
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
end

return M
