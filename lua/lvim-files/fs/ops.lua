-- lvim-files.fs.ops: the ONE file-operations engine both presentations apply through.
-- create / rename / move / copy / delete, with the whole-editor bookkeeping an fs change
-- implies: every rename/move first asks the running LSP clients `workspace/willRenameFiles`
-- (and applies the returned workspace edits, so imports stay correct), open buffers are
-- re-pointed at the new path (or wiped on delete), `workspace/didRenameFiles` is notified
-- after, and a `User LvimFiles<Op>` autocmd fires for other plugins. Deletes go to the
-- trash (`gio trash`) when available and enabled, else remove from disk.
--
-- The fs calls themselves are the SYNCHRONOUS vim.uv forms: an op list must apply strictly
-- in order (a created directory must exist before a move into it), and each call is fast.
--
---@module "lvim-files.fs.ops"

local config = require("lvim-files.config")

local uv = vim.uv
local api = vim.api

local M = {}

--- Fire the public `User LvimFiles<event>` autocmd with the op payload.
---@param event string   "Create" | "Rename" | "Move" | "Copy" | "Delete"
---@param data table     { path?, from?, to? }
local function fire(event, data)
    api.nvim_exec_autocmds("User", { pattern = "LvimFiles" .. event, data = data })
end

--- Whether a trash backend is available (`gio trash`; memoized).
---@type boolean|nil
local has_trash = nil
---@return boolean
function M.trash_available()
    if has_trash == nil then
        has_trash = vim.fn.executable("gio") == 1
    end
    return has_trash
end

--- Whether deletes will actually go to the trash under the current config.
---@return boolean
function M.uses_trash()
    return config.edit.trash ~= false and M.trash_available()
end

--- Ask every running client that supports `workspace/willRenameFiles` about the rename and
--- apply the workspace edits it answers with (imports/requires tracking the file). Sync with
--- a short timeout so the edits land BEFORE the file moves (the protocol's contract).
---@param from string
---@param to string
local function lsp_will_rename(from, to)
    if config.lsp_rename == false then
        return
    end
    local params = { files = { { oldUri = vim.uri_from_fname(from), newUri = vim.uri_from_fname(to) } } }
    for _, client in ipairs(vim.lsp.get_clients()) do
        if client:supports_method("workspace/willRenameFiles") then
            local ok, res = pcall(client.request_sync, client, "workspace/willRenameFiles", params, 1000)
            if ok and res and res.result then
                pcall(vim.lsp.util.apply_workspace_edit, res.result, client.offset_encoding)
            end
        end
    end
end

--- Notify `workspace/didRenameFiles` after the move happened.
---@param from string
---@param to string
local function lsp_did_rename(from, to)
    if config.lsp_rename == false then
        return
    end
    local params = { files = { { oldUri = vim.uri_from_fname(from), newUri = vim.uri_from_fname(to) } } }
    for _, client in ipairs(vim.lsp.get_clients()) do
        if client:supports_method("workspace/didRenameFiles") then
            pcall(client.notify, client, "workspace/didRenameFiles", params)
        end
    end
end

--- Re-point every loaded buffer at/under `from` to its `to` counterpart, so an open file
--- keeps its window after a rename/move. An unmodified buffer is re-read (`:edit`) so it
--- re-associates cleanly (no E13 on the next write); a modified one only gets the new name.
---@param from string
---@param to string
local function retarget_buffers(from, to)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            local name = api.nvim_buf_get_name(buf)
            local new
            if name == from then
                new = to
            elseif name:sub(1, #from + 1) == from .. "/" then
                new = to .. name:sub(#from + 1)
            end
            if new then
                pcall(api.nvim_buf_set_name, buf, new)
                if not vim.bo[buf].modified then
                    api.nvim_buf_call(buf, function()
                        pcall(vim.cmd, "silent! edit!")
                    end)
                end
            end
        end
    end
end

--- Wipe every UNMODIFIED loaded buffer at/under a deleted path (a modified buffer is kept —
--- the user still owns those changes).
---@param path string
local function drop_buffers(path)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and not vim.bo[buf].modified then
            local name = api.nvim_buf_get_name(buf)
            if name == path or name:sub(1, #path + 1) == path .. "/" then
                pcall(api.nvim_buf_delete, buf, { force = true })
            end
        end
    end
end

--- Whether anything exists at `path` (lstat: a broken symlink still counts).
---@param path string
---@return boolean
function M.exists(path)
    return uv.fs_lstat(path) ~= nil
end

--- Ensure the parent directory of `path` exists (recursive mkdir).
---@param path string
---@return boolean ok, string? err
local function ensure_parent(path)
    local parent = vim.fs.dirname(path)
    if parent == "" or M.exists(parent) then
        return true
    end
    local ok = pcall(vim.fn.mkdir, parent, "p")
    if not ok then
        return false, "could not create " .. parent
    end
    return true
end

--- Create a file or directory at `path` (recursive: intermediate directories are created).
---@param path string
---@param is_dir? boolean
---@return boolean ok, string? err
function M.create(path, is_dir)
    if M.exists(path) then
        return false, path .. " already exists"
    end
    local ok, err = ensure_parent(path)
    if not ok then
        return false, err
    end
    if is_dir then
        local mk = pcall(vim.fn.mkdir, path, "p")
        if not mk then
            return false, "could not create directory " .. path
        end
    else
        local fd, ferr = uv.fs_open(path, "wx", 420) -- 0644
        if not fd then
            return false, ferr or ("could not create " .. path)
        end
        uv.fs_close(fd)
    end
    fire("Create", { path = path, dir = is_dir == true })
    return true
end

--- Rename/move `from` to `to` (one engine for both — a move IS a rename across parents).
--- Refuses to overwrite. Runs the LSP willRename → fs_rename → buffer retarget → didRename
--- chain and fires `User LvimFilesRename` / `LvimFilesMove`.
---@param from string
---@param to string
---@return boolean ok, string? err
function M.rename(from, to)
    if from == to then
        return true
    end
    if not M.exists(from) then
        return false, from .. " does not exist"
    end
    if M.exists(to) then
        return false, to .. " already exists"
    end
    local ok, err = ensure_parent(to)
    if not ok then
        return false, err
    end
    lsp_will_rename(from, to)
    local rok, rerr = uv.fs_rename(from, to)
    if not rok then
        return false, rerr or ("could not rename " .. from)
    end
    retarget_buffers(from, to)
    lsp_did_rename(from, to)
    local moved = vim.fs.dirname(from) ~= vim.fs.dirname(to)
    fire(moved and "Move" or "Rename", { from = from, to = to })
    return true
end

--- Recursively copy a file / directory / symlink.
---@param from string
---@param to string
---@return boolean ok, string? err
local function copy_any(from, to)
    local st = uv.fs_lstat(from)
    if not st then
        return false, from .. " does not exist"
    end
    if st.type == "directory" then
        local mok, merr = uv.fs_mkdir(to, st.mode)
        if not mok then
            return false, merr or ("could not create " .. to)
        end
        local handle = uv.fs_scandir(from)
        while handle do
            local name = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            local ok, err = copy_any(from .. "/" .. name, to .. "/" .. name)
            if not ok then
                return false, err
            end
        end
        return true
    elseif st.type == "link" then
        local target = uv.fs_readlink(from)
        if not target then
            return false, "could not read symlink " .. from
        end
        local sok, serr = uv.fs_symlink(target, to)
        if not sok then
            return false, serr or ("could not link " .. to)
        end
        return true
    end
    local cok, cerr = uv.fs_copyfile(from, to)
    if not cok then
        return false, cerr or ("could not copy " .. from)
    end
    return true
end

--- Copy `from` to `to` (recursive for directories). Refuses to overwrite.
---@param from string
---@param to string
---@return boolean ok, string? err
function M.copy(from, to)
    if from == to then
        return false, "source and target are the same"
    end
    -- Refuse a copy whose TARGET sits inside the SOURCE subtree (e.g. `/a` → `/a/a`): the recursive walk
    -- would scan `from`, find the freshly created `to` inside it, and copy that in turn — an unbounded
    -- descent (`/a/a/a/…`) that spews nested directories on disk until the path length blows up. `rename`
    -- is safe from this only because the OS rejects it; the copy engine must guard it itself.
    if to:sub(1, #from + 1) == from .. "/" then
        return false, "cannot copy " .. from .. " into itself"
    end
    if M.exists(to) then
        return false, to .. " already exists"
    end
    local ok, err = ensure_parent(to)
    if not ok then
        return false, err
    end
    ok, err = copy_any(from, to)
    if not ok then
        return false, err
    end
    fire("Copy", { from = from, to = to })
    return true
end

--- Delete `path` — to the trash (`gio trash`) when enabled + available, else from disk
--- (recursive). Unmodified buffers on the deleted path are wiped.
---@param path string
---@return boolean ok, string? err, string? method  method = "trash" | "delete"
function M.delete(path)
    if not M.exists(path) then
        return false, path .. " does not exist"
    end
    local method
    if M.uses_trash() then
        local res = vim.system({ "gio", "trash", path }, { text = true }):wait()
        if res.code ~= 0 then
            return false, ((res.stderr or "gio trash failed"):gsub("%s+$", ""))
        end
        method = "trash"
    else
        if vim.fn.delete(path, "rf") ~= 0 then
            return false, "could not delete " .. path
        end
        method = "delete"
    end
    drop_buffers(path)
    fire("Delete", { path = path, method = method })
    return true, nil, method
end

return M
