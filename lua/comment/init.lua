local M = {}

local ns = vim.api.nvim_create_namespace("comment.nvim")

local config = {
  signs = true,
  sign_text = "C",
  virtual_line_prefix = "  comment ",
  mappings = {
    add = "<leader>ca",
    toggle = "<leader>ct",
    delete = "<leader>cd",
  },
}

local state = {
  buffers = {},
}

local function get_buf_state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  state.buffers[bufnr] = state.buffers[bufnr] or {
    comments = {},
    next_id = 1,
    visible = true,
    editing = nil,
  }
  return state.buffers[bufnr]
end

local function clamp_line(bufnr, lnum)
  local count = vim.api.nvim_buf_line_count(bufnr)
  return math.max(1, math.min(lnum, count))
end

local function normalize_range(bufnr, start_line, end_line)
  start_line = clamp_line(bufnr, start_line)
  end_line = clamp_line(bufnr, end_line or start_line)

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return start_line, end_line
end

local function sign_hl()
  return vim.fn.hlexists("CommentNvimSign") == 1 and "CommentNvimSign" or "Comment"
end

local function text_hl()
  return vim.fn.hlexists("CommentNvimText") == 1 and "CommentNvimText" or "Comment"
end

local function compact_comment_text(text)
  text = vim.trim(text or "")
  if text == "" then
    return ""
  end
  return text:gsub("\n+", " ")
end

local function render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local buf_state = get_buf_state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  if not buf_state.visible then
    return
  end

  for _, item in ipairs(buf_state.comments) do
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if item.start_line <= line_count then
      local end_line = math.min(item.end_line, line_count)
      local line_label = item.start_line == end_line and tostring(item.start_line)
        or string.format("%d-%d", item.start_line, end_line)
      local virtual_text = config.virtual_line_prefix .. line_label .. ": " .. item.text

      vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0, {
        virt_lines = {
          {
            { virtual_text, text_hl() },
          },
        },
        virt_lines_above = false,
        right_gravity = false,
      })

      if config.signs then
        for lnum = item.start_line, end_line do
          vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
            sign_text = config.sign_text,
            sign_hl_group = sign_hl(),
          })
        end
      end
    end
  end
end

local function find_comments_at_line(buf_state, lnum)
  local matches = {}

  for index, item in ipairs(buf_state.comments) do
    if lnum >= item.start_line and lnum <= item.end_line then
      table.insert(matches, {
        index = index,
        item = item,
      })
    end
  end

  return matches
end

local function remove_editing_lines(bufnr, edit)
  if not edit or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local last_line = vim.api.nvim_buf_line_count(bufnr)
  if edit.insert_line < 1 or edit.insert_line > last_line then
    return
  end

  local ok = vim.api.nvim_buf_get_lines(bufnr, edit.insert_line - 1, edit.insert_line, false)
  if ok[1] and ok[1]:sub(1, #edit.marker) == edit.marker then
    vim.api.nvim_buf_set_lines(bufnr, edit.insert_line - 1, edit.insert_line, false, {})
  end
end

local function finish_edit(bufnr, save)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_state = get_buf_state(bufnr)
  local edit = buf_state.editing

  if not edit then
    return
  end

  local line = ""
  if vim.api.nvim_buf_is_valid(bufnr) and edit.insert_line <= vim.api.nvim_buf_line_count(bufnr) then
    line = vim.api.nvim_buf_get_lines(bufnr, edit.insert_line - 1, edit.insert_line, false)[1] or ""
  end

  remove_editing_lines(bufnr, edit)

  if save then
    local text = compact_comment_text(line:sub(#edit.marker + 1))
    if text ~= "" then
      table.insert(buf_state.comments, {
        id = buf_state.next_id,
        start_line = edit.start_line,
        end_line = edit.end_line,
        text = text,
      })
      buf_state.next_id = buf_state.next_id + 1
      buf_state.visible = true
    end
  end

  if edit.winid and vim.api.nvim_win_is_valid(edit.winid) then
    vim.api.nvim_win_set_cursor(edit.winid, { edit.cursor_line, edit.cursor_col })
  end

  pcall(vim.api.nvim_del_augroup_by_id, edit.augroup)
  buf_state.editing = nil
  render(bufnr)
end

local function start_edit(bufnr, start_line, end_line)
  local buf_state = get_buf_state(bufnr)
  if buf_state.editing then
    finish_edit(bufnr, true)
  end

  start_line, end_line = normalize_range(bufnr, start_line, end_line)
  local insert_index = end_line
  local insert_line = end_line + 1
  local marker = "COMMENT: "

  vim.api.nvim_buf_set_lines(bufnr, insert_index, insert_index, false, { marker })
  vim.api.nvim_win_set_cursor(0, { insert_line, #marker })
  vim.cmd("startinsert!")

  local augroup = vim.api.nvim_create_augroup("CommentNvimEdit" .. bufnr, { clear = true })
  buf_state.editing = {
    augroup = augroup,
    bufnr = bufnr,
    cursor_line = start_line,
    cursor_col = 0,
    end_line = end_line,
    insert_line = insert_line,
    marker = marker,
    start_line = start_line,
    winid = vim.api.nvim_get_current_win(),
  }

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    buffer = bufnr,
    once = true,
    callback = function()
      finish_edit(bufnr, true)
    end,
  })
end

function M.add_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  start_edit(bufnr, lnum, lnum)
end

function M.add_range(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  start_edit(bufnr, start_line, end_line)
end

function M.add_visual()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  M.add_range(start_pos[2], end_pos[2])
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_state = get_buf_state(bufnr)
  buf_state.visible = not buf_state.visible
  render(bufnr)
end

function M.show()
  local bufnr = vim.api.nvim_get_current_buf()
  get_buf_state(bufnr).visible = true
  render(bufnr)
end

function M.hide()
  local bufnr = vim.api.nvim_get_current_buf()
  get_buf_state(bufnr).visible = false
  render(bufnr)
end

function M.delete_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_state = get_buf_state(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local matches = find_comments_at_line(buf_state, lnum)

  if #matches == 0 then
    vim.notify("No comment at cursor", vim.log.levels.INFO)
    return
  end

  table.remove(buf_state.comments, matches[#matches].index)
  render(bufnr)
end

function M.clear()
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_state = get_buf_state(bufnr)
  buf_state.comments = {}
  buf_state.editing = nil
  render(bufnr)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  vim.api.nvim_create_user_command("CommentAdd", function()
    M.add_line()
  end, {})

  vim.api.nvim_create_user_command("CommentAddRange", function(command)
    M.add_range(command.line1, command.line2)
  end, { range = true })

  vim.api.nvim_create_user_command("CommentToggle", function()
    M.toggle()
  end, {})

  vim.api.nvim_create_user_command("CommentShow", function()
    M.show()
  end, {})

  vim.api.nvim_create_user_command("CommentHide", function()
    M.hide()
  end, {})

  vim.api.nvim_create_user_command("CommentDelete", function()
    M.delete_at_cursor()
  end, {})

  vim.api.nvim_create_user_command("CommentClear", function()
    M.clear()
  end, {})

  if config.mappings then
    local map = vim.keymap.set
    map("n", config.mappings.add, M.add_line, { desc = "Add comment to line" })
    map("x", config.mappings.add, M.add_visual, { desc = "Add comment to selection" })
    map("n", config.mappings.toggle, M.toggle, { desc = "Toggle comments" })
    map("n", config.mappings.delete, M.delete_at_cursor, { desc = "Delete comment at cursor" })
  end
end

return M
