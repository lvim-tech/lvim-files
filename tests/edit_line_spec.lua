-- The edit view: a line is the entry's NAME; its icon is inline virtual text (the cursor skips it, a rename
-- reads what was typed). parse_line still drops a leading icon from a pasted line — only an icon.

local diff = require("lvim-files.fs.diff")
local render = require("lvim-files.render")

describe("lvim-files: the edit view's lines")

it("a line holds the name; the icon is a virtual span", function()
    local line, spans = render.edit_line({ name = "init.lua", type = "file", path = "/x/init.lua" })
    eq("init.lua", line)
    eq(0, spans[1][1])
    eq(0, spans[1][2], "zero width: not text")
    truthy(type(spans[1][4]) == "string" and spans[1][4] ~= "", "the icon glyph rides along")
end)

it("parse_line drops a leading icon, image cells included, and nothing else", function()
    local cells = vim.fn.nr2char(0x10EEEE) .. "\u{0305}\u{0305}" .. vim.fn.nr2char(0x10EEEE) .. "\u{0305}\u{030D}"
    eq("init.lua", (diff.parse_line(cells .. " init.lua")), "image cells")
    eq("notes.md", (diff.parse_line("\u{f0219} notes.md")), "a Nerd glyph")
    eq("ä b.txt", (diff.parse_line("ä b.txt")), "an ordinary first letter stays")
    eq("plain.lua", (diff.parse_line("plain.lua")))
    local name, is_dir = diff.parse_line("src/")
    eq("src", name)
    eq(true, is_dir)
end)
