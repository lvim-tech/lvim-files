# lvim-files

One file manager, two presentations, one core. Part of the lvim-tech ecosystem
([lvim-utils](https://github.com/lvim-tech/lvim-utils) palette/merge,
[lvim-ui](https://github.com/lvim-tech/lvim-ui) windows).

- **Tree panel** — a persistent side panel (`winfixwidth` split): lazy async
  directory tree, entry icons, git status badges (with ancestor propagation) and
  per-file diagnostics badges, a live filter bar (dotfiles / git-ignored), full
  file operations (create, rename, delete, copy/cut/paste), open-in-picked-window,
  open in a vertical / horizontal split or a new tab, **follow** (reveal the current
  buffer's file as you move), and a fuzzy jump within the tree. Opening it focuses
  the tree.
- **Edit view** — a directory as a **modifiable buffer** in a centred float:
  editing the text IS the file operation. Rename a line to rename the file,
  delete a line to delete it, add a line to create (a trailing `/` creates a
  directory), `dd` … `p` across directories to move, duplicate a line to copy.
  On save the buffer is diffed against per-line identity marks into an **ordered
  operation list**, shown in a confirm panel, and applied.

Both views share ONE filesystem model (async `vim.uv` scan, lazy per-directory
loading, `fs_event` watchers), ONE operations engine and ONE decoration
pipeline:

- every rename/move first asks the running LSP clients
  `workspace/willRenameFiles` and applies the returned edits (imports stay
  correct), then notifies `workspace/didRenameFiles`;
- open buffers are re-pointed after a rename/move and dropped after a delete;
- deletes go to the **trash** (`gio trash`) when available (configurable);
- every operation fires a `User LvimFiles*` autocmd for other plugins.

## Installation

Requires Neovim >= 0.11, [lvim-utils](https://github.com/lvim-tech/lvim-utils)
and [lvim-ui](https://github.com/lvim-tech/lvim-ui). Optional integrations:
[lvim-icons](https://github.com/lvim-tech/lvim-icons) (entry icons),
[lvim-winpick](https://github.com/lvim-tech/lvim-winpick) (open in a picked
window), [lvim-picker](https://github.com/lvim-tech/lvim-picker) (fuzzy tree
jump).

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab
and install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no
external plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-files" },
})
require("lvim-files").setup({})
```

## Setup

The full default configuration — every option at its default value (`setup()`
merges your overrides into this live config):

```lua
require("lvim-files").setup({
    panel = {
        width = 34, -- columns (>1) or a fraction of the screen (<=1)
        side = "left", -- "left" | "right"
        auto_close_on_open = false, -- close the panel after opening a file through it
        close_if_last = false, -- close the tree when it would be the last window in the tab
        focus_on_open = true, -- move the cursor into the tree when it opens
        follow = true, -- reveal + select the current buffer's file in the tree as windows/buffers change
        auto_collapse = false, -- when a file is revealed, keep only its branch open (collapse the others)
        input = "native", -- rename/add prompt: "native" (Neovim's vim.ui.input) or "popup" (the lvim-ui input)
        title = "LVIM FILES", -- the panel winbar title (false = none)
        keys = {
            open = { "<CR>", "l" }, -- expand a directory / open a file
            close_node = "h", -- collapse, or jump to the parent row
            open_pick = "o", -- open in a window chosen via lvim-winpick
            open_vsplit = "<C-v>", -- open the file in a vertical split
            open_split = "<C-x>", -- open the file in a horizontal split
            open_tab = "<C-t>", -- open the file in a new tab
            add = "a", -- create (trailing "/" = directory)
            rename = "r", -- rename the entry
            delete = "d", -- delete the entry (trash-aware)
            copy = "c", -- copy: the entry under the cursor, or the whole VISUAL selection
            cut = "x", -- cut (moves on paste): likewise, single or selection
            paste = "p", -- paste EVERY clipboard entry into the directory under the cursor
            copy_path = "y", -- normal: yank the absolute path · VISUAL: copy the selected entries
            info = "i", -- everything known about the entry (a read-only popup)
            root_up = "-", -- re-root one directory up
            root_cwd = "~", -- re-root at the current working directory
            find = "/", -- fuzzy jump in the tree (lvim-picker)
            toggle_dotfiles = ".", -- toggle the dotfiles filter
            toggle_gitignore = "H", -- toggle the git-ignored filter
            refresh = "R", -- rescan the tree + git status
            edit_mode = "e", -- open the EDIT view on the directory
            help = "?", -- the keymap cheatsheet
            close = "q", -- close the panel
        },
    },
    edit = {
        confirm = true, -- show the op-list confirm panel before applying
        trash = true, -- delete to trash (gio trash) when available
        keys = {
            go_in = { "<CR>", "l" }, -- re-target into the directory on the line
            go_out = "h", -- re-target to the parent directory
            synchronize = "=", -- diff -> confirm -> apply (also :w)
            close = "q", -- close (pending edits guarded by a confirm)
        },
    },
    filters = {
        dotfiles = true, -- show dotfiles on open
        gitignore = true, -- show git-ignored entries on open
    },
    git = {
        enabled = true, -- git status decorations
        debounce = 150, -- ms to coalesce git status refreshes
    },
    diagnostics = true, -- max-severity diagnostics badge per entry
    hijack_netrw = false, -- open directory buffers in the EDIT view
    lsp_rename = true, -- workspace/willRenameFiles before rename/move
    icons = {
        fold_open = vim.fn.nr2char(0xF0D7, 1), --   expanded directory
        fold_closed = vim.fn.nr2char(0xF0DA, 1), --   collapsed directory
        guide = "│", -- indent guide column
        dir = vim.fn.nr2char(0xF07B, 1), --   fallback directory icon
        dir_open = vim.fn.nr2char(0xF07C, 1), --   fallback open directory
        file = vim.fn.nr2char(0xF15B, 1), --   fallback file icon
        symlink = vim.fn.nr2char(0xF481, 1), --   symlink marker
        git = {
            added = vim.fn.nr2char(0xF067, 1), -- 
            modified = vim.fn.nr2char(0xF444, 1), -- 
            deleted = vim.fn.nr2char(0xF00D, 1), -- 
            renamed = vim.fn.nr2char(0xF061, 1), -- 
            untracked = vim.fn.nr2char(0xF128, 1), -- 
            ignored = vim.fn.nr2char(0xF070, 1), -- 
            conflict = vim.fn.nr2char(0xF419, 1), -- 
        },
        diag = {
            error = vim.fn.nr2char(0xF057, 1), -- 
            warn = vim.fn.nr2char(0xF071, 1), -- 
            info = vim.fn.nr2char(0xF05A, 1), -- 
            hint = vim.fn.nr2char(0xF059, 1), -- 
        },
    },
})
```

## Command

```
:LvimFiles                  toggle the tree panel
:LvimFiles panel [dir]      toggle the tree panel (optionally rooted at dir)
:LvimFiles focus            focus the panel (opening it if needed)
:LvimFiles close            close the panel and the edit view
:LvimFiles edit [dir]       open the EDIT view (default: the current file's directory)
```

Subcommands and directory arguments tab-complete.

## The edit view

`:LvimFiles edit` opens the directory as a modifiable buffer — one `icon name`
line per entry, each line carrying its entry's identity as a hidden extmark.
Edit freely, then synchronize with `:w` (or `=`):

| Buffer edit                          | Operation                              |
| ------------------------------------ | -------------------------------------- |
| change a name on a line              | rename                                 |
| delete a line (`dd`)                 | delete                                 |
| add a line `name`                    | create a file                          |
| add a line `name/`                   | create a directory (recursive)         |
| `dd` … navigate … `p`                | move across directories                |
| `yy` … `p` (other directory)         | copy                                   |
| swap two names                       | rename both (cycle-safe via temp hop)  |

Navigation re-targets the same buffer: `l`/`<CR>` on a directory line enters
it, `h` goes to the parent — the border title is the breadcrumb
(`root ➤ sub ➤ dir`). Pending edits in every visited directory are kept and
applied together on the next synchronize; closing with unapplied operations
asks first.

The ordered operation list is presented in a confirm panel (create = green,
change = yellow, delete = red; conflicting operations are shown with a note and
skipped). `<CR>` applies, `<Esc>` cancels. Set `edit.confirm = false` to apply
directly.

## Events

Every applied operation fires a `User` autocmd with the paths in `data`:

```
LvimFilesCreate   { path, dir }
LvimFilesRename   { from, to }      (same parent directory)
LvimFilesMove     { from, to }      (parent changed)
LvimFilesCopy     { from, to }
LvimFilesDelete   { path, method }  (method = "trash" | "delete")
```

## API

| Function                                   | Description                                |
| ------------------------------------------ | ------------------------------------------ |
| `require("lvim-files").setup(opts)`        | merge options into the live config         |
| `require("lvim-files").open(enter?, dir?)` | open the tree panel                        |
| `require("lvim-files").close()`            | close the tree panel                       |
| `require("lvim-files").toggle(dir?)`       | toggle the tree panel                      |
| `require("lvim-files").focus()`            | focus the panel (opening it if needed)     |
| `require("lvim-files").reveal(path)`       | expand to + select a path in the tree      |
| `require("lvim-files").edit(dir?)`         | open the edit view on a directory          |

## Cursor integration

The panel buffer's filetype is `lvim-files`. Register it as a persistent-panel
filetype with the lvim-utils cursor module so the hardware cursor hides while
the panel is focused (and stays visible in the code beside it):

```lua
require("lvim-utils.cursor").setup({
    panel_ft = { "lvim-files" },
})
```

The edit view keeps a visible cursor (it is a real editing buffer).

## Highlights

All groups derive from the live lvim-utils palette and re-derive on
`ColorScheme` / palette sync.

```
LvimFilesDir / File / Symlink / Exec / Cut     entry names
LvimFilesRoot                                  the root path band
LvimFilesGuide / Fold / Empty                  tree chrome
LvimFilesGitAdded / Modified / Deleted /
    Renamed / Untracked / Ignored / Conflict   git badges
LvimFilesDiagError / Warn / Info / Hint        diagnostics badges
LvimFilesOpAdd / Change / Delete (+Active)     confirm panel rows
LvimFilesOpNote                                conflict notes
LvimFilesFilterKey / On / Off                  the filter bar buttons
```

## Copy, cut, paste

Select the rows (`V`, `j`/`k`) and press `y` (or `c`) to copy them, `x` to cut them, then `p` in the target
directory — the whole selection lands there. Without a selection the keys act on the entry under the cursor.
A copy stays on the clipboard (drop the same set into several directories); a cut is consumed by the paste.

A name that already exists is never an error and never silently overwritten: the paste offers a free name
(`a.txt` → `a (copy).txt`, pre-filled and editable), an explicit **Overwrite**, or **Skip** — with
*…for all* answers so a ten-file paste is not ten questions.

`i` shows everything known about the entry — path, type (a symlink's target, and whether it is broken), size
(a directory's is its contents, walked with a cap so the popup can never hang), permissions, owner, the three
timestamps, and its git status.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
