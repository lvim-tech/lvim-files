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

    health.info(
        'Register the panel filetype in the cursor module: panel_ft = { "lvim-files" } '
            .. "(lvim-utils cursor setup) so the hardware cursor hides while the panel is focused."
    )
end

return M
