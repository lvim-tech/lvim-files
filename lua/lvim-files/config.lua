-- lvim-files.config: the LIVE plugin configuration. `setup()` merges user options into this table
-- in place (via lvim-utils.utils.merge), so every reader `require("lvim-files.config")` sees the
-- effective values. Runtime state never lives here (see the per-view modules).
--
---@module "lvim-files.config"

---@class LvimFilesPanelKeys
---@field open string|string[]          expand a directory / open a file (jump to it)
---@field close_node string|string[]    collapse the node, or jump to its parent
---@field open_pick string|string[]     open the file in a window chosen via lvim-winpick
---@field open_vsplit string|string[]   open the file in a vertical split
---@field open_split string|string[]    open the file in a horizontal split
---@field open_tab string|string[]      open the file in a new tab
---@field add string|string[]           create a file (trailing "/" = directory) under the node
---@field rename string|string[]        rename the node
---@field delete string|string[]        delete the node (trash-aware)
---@field copy string|string[]          mark the node for copy
---@field cut string|string[]           mark the node for cut (move on paste)
---@field paste string|string[]         paste the marked node into the directory under the cursor
---@field copy_path string|string[]     yank the node's absolute path
---@field root_up string|string[]       re-root the panel one directory up
---@field root_cwd string|string[]      re-root the panel at the current working directory
---@field find string|string[]          fuzzy-jump to a loaded entry (lvim-picker)
---@field toggle_dotfiles string|string[]   toggle the dotfiles filter
---@field toggle_gitignore string|string[]  toggle the gitignore filter
---@field refresh string|string[]       rescan the tree (and git status)
---@field edit_mode string|string[]     open the EDIT view on the directory under the cursor
---@field help string|string[]          show the keymap cheatsheet
---@field close string|string[]         close the panel

---@class LvimFilesPanelConfig
---@field width number                  panel width — a column count (>1) or a fraction of the screen (≤1)
---@field side string                   "left" | "right"
---@field padding { left?: integer, right?: integer }  blank columns around the tree rows (title band excluded)
---@field scrollbar boolean             right-edge thumb while the tree overflows the window
---@field auto_close_on_open boolean    close the panel after opening a file
---@field close_if_last boolean         close the tree when it would be the last window in the tab
---@field focus_on_open boolean         move the cursor into the tree when it opens
---@field follow boolean                reveal the current buffer's file in the tree as windows/buffers change
---@field auto_collapse boolean         when a file is revealed/expanded, keep only its branch open (opt-in)
---@field input "popup"|"native"        text prompts (rename/add): the lvim-ui popup, or Neovim's vim.ui.input
---@field title string|false            the panel winbar title (false = none)
---@field keys LvimFilesPanelKeys

---@class LvimFilesEditKeys
---@field go_in string|string[]         re-target the buffer into the directory on the line
---@field go_out string|string[]        re-target the buffer to the parent directory
---@field synchronize string|string[]   diff the buffer → confirm → apply (also `:w`)
---@field close string|string[]         close the edit view (pending edits are discarded)
---@field toggle_dotfiles string|string[]   toggle the dotfiles filter (hidden entries are untouched on sync)
---@field toggle_gitignore string|string[]  toggle the gitignore filter (hidden entries are untouched on sync)

---@class LvimFilesEditConfig
---@field confirm boolean               show the op-list confirm panel before applying (false = apply directly)
---@field trash boolean                 delete to trash (`gio trash`) when available
---@field keys LvimFilesEditKeys

---@class LvimFilesFiltersConfig
---@field dotfiles boolean              show dotfiles on open
---@field gitignore boolean             show git-ignored entries on open

---@class LvimFilesGitConfig
---@field enabled boolean               decorate entries with git status
---@field debounce integer              ms to coalesce git status refreshes

---@class LvimFilesGitIcons
---@field added string
---@field modified string
---@field deleted string
---@field renamed string
---@field untracked string
---@field ignored string
---@field conflict string

---@class LvimFilesDiagIcons
---@field error string
---@field warn string
---@field info string
---@field hint string

---@class LvimFilesIcons
---@field fold_open string              expanded-directory marker
---@field fold_closed string            collapsed-directory marker
---@field guide string                  indent guide column
---@field dir string                    fallback directory icon (lvim-icons wins when present)
---@field dir_open string               fallback open-directory icon
---@field file string                   fallback file icon
---@field symlink string                symlink marker (after the name)
---@field git LvimFilesGitIcons
---@field diag LvimFilesDiagIcons

---@class LvimFilesConfig
---@field panel LvimFilesPanelConfig
---@field edit LvimFilesEditConfig
---@field filters LvimFilesFiltersConfig
---@field git LvimFilesGitConfig
---@field diagnostics boolean           decorate entries with a max-severity diagnostics badge
---@field hijack_netrw boolean          open directory buffers in the EDIT view instead of netrw
---@field lsp_rename boolean            ask LSP `workspace/willRenameFiles` before rename/move
---@field icons LvimFilesIcons
local M = {
    panel = {
        width = 34,
        side = "left",
        -- Breathing room around the tree ROWS (the title band always spans the full width). When `scrollbar` is
        -- on, ONE more column is reserved on the right for the thumb, so it never sits on the content.
        padding = { left = 1, right = 1 },
        scrollbar = false, -- right-edge thumb while the tree overflows the window

        auto_close_on_open = false, -- close the panel after opening a file through it
        close_if_last = false, -- OPT-IN: close the tree when it would be left as the last window in the tab
        focus_on_open = true, -- move the cursor INTO the tree when it opens (else focus stays in the editor)
        follow = true, -- reveal + select the current buffer's file in the tree as you switch windows/buffers
        auto_collapse = false, -- OPT-IN: when a file is revealed, collapse every OTHER branch (keep only its path open)
        input = "native", -- text prompts (rename / add): "native" = Neovim's vim.ui.input (default) · "popup" = the lvim-ui input
        title = "LVIM FILES",
        keys = {
            open = { "<CR>", "l" },
            close_node = "h",
            open_pick = "o",
            open_vsplit = "<C-v>", -- open the file in a VERTICAL split
            open_split = "<C-x>", -- open the file in a HORIZONTAL split
            open_tab = "<C-t>", -- open the file in a NEW tab
            add = "a",
            rename = "r",
            delete = "d",
            copy = "c",
            cut = "x",
            paste = "p",
            copy_path = "y",
            root_up = "-",
            root_cwd = "~",
            find = "/",
            toggle_dotfiles = ".",
            toggle_gitignore = "H",
            refresh = "R",
            edit_mode = "e",
            help = "?",
            close = "q",
        },
    },
    edit = {
        confirm = true,
        trash = true,
        keys = {
            go_in = { "<CR>", "l" },
            go_out = "h",
            synchronize = "=",
            close = "q",
            toggle_dotfiles = ".",
            toggle_gitignore = "H",
        },
    },
    filters = {
        dotfiles = true,
        gitignore = true,
    },
    git = {
        enabled = true,
        debounce = 150,
    },
    diagnostics = true,
    hijack_netrw = false,
    lsp_rename = true,
    icons = {
        fold_open = "", -- nf-fa-caret_down
        fold_closed = "", -- nf-fa-caret_right
        guide = "│",
        dir = "", -- nf-fa-folder
        dir_open = "", -- nf-fa-folder_open
        file = "", -- nf-fa-file
        symlink = "", -- nf-oct-file_symlink_file
        git = {
            added = "", -- nf-fa-plus
            modified = "", -- nf-oct-dot_fill
            deleted = "", -- nf-fa-close
            renamed = "", -- nf-fa-arrow_right
            untracked = "", -- nf-fa-question
            ignored = "", -- nf-fa-eye_slash
            conflict = "", -- nf-oct-git_merge
        },
        diag = {
            error = "", -- nf-fa-times_circle
            warn = "", -- nf-fa-exclamation_triangle
            info = "", -- nf-fa-info_circle
            hint = "", -- nf-fa-question_circle
        },
    },
}

return M
