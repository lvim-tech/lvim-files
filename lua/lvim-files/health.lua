-- lvim-files.health: `:checkhealth lvim-files` — the hard dependencies (lvim-utils,
-- lvim-ui), the external tools the decorations and the trash-aware delete rely on (git,
-- gio), and the optional lvim-tech integrations (lvim-icons, lvim-winpick, lvim-picker).
-- Read-only: reports state, changes nothing.
--
---@module "lvim-files.health"

local M = {}

--- Optional integrations: module → what it powers.
---@type { [1]: string, [2]: string }[]
local OPTIONAL = {
    { "lvim-icons", "file / directory icons" },
    { "lvim-winpick", "open-in-picked-window (o)" },
    { "lvim-picker", "fuzzy tree jump (/)" },
}

function M.check()
    local health = vim.health
    health.start("lvim-files")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (extmark invalidation, vim.system).")
    end

    for _, mod in ipairs({ "lvim-utils", "lvim-ui" }) do
        if pcall(require, mod) then
            health.ok(mod .. " is installed")
        else
            health.error(mod .. " is required (palette / merge / surface UI).")
        end
    end

    if vim.fn.executable("git") == 1 then
        health.ok("git found — status decorations available")
    else
        health.warn("git not found — git badges and the gitignore filter are disabled.")
    end

    if vim.fn.executable("gio") == 1 then
        health.ok("gio found — deletes go to the trash (edit.trash)")
    else
        health.warn("gio not found — deletes remove from disk (after the confirm).")
    end

    for _, o in ipairs(OPTIONAL) do
        if pcall(require, o[1]) then
            health.ok(o[1] .. " is installed (" .. o[2] .. ")")
        else
            health.info(o[1] .. " not installed — " .. o[2] .. " degrades gracefully.")
        end
    end

    -- The panel self-registers its filetype for cursor hiding from setup() (cursor.register mirrors it into
    -- the live config.cursor.panel_ft registry), so no central-config edit is needed. Probe that registry
    -- rather than telling the user to hand-register it — the manual step is stale after self-registration.
    local ok_cfg, ucfg = pcall(require, "lvim-utils.config")
    local registered = false
    if ok_cfg and type(ucfg.cursor) == "table" and type(ucfg.cursor.panel_ft) == "table" then
        for _, ft in ipairs(ucfg.cursor.panel_ft) do
            if ft == "lvim-files" then
                registered = true
                break
            end
        end
    end
    if registered then
        health.ok('panel filetype "lvim-files" self-registered for cursor hiding (panel_ft)')
    else
        health.info(
            'panel filetype "lvim-files" not yet registered — it self-registers on setup(); '
                .. 'run require("lvim-files").setup() (or open the panel once) to enable cursor hiding.'
        )
    end
end

return M
