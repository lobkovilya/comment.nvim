local M = {}

local ns = vim.api.nvim_create_namespace("comment.nvim")

local config = {
  signs = true,
  sign_text = "C",
  max_width = 72,
  box = {
    indent = "  ",
    top_left = "╭",
    top_right = "╮",
    bottom_left = "╰",
    bottom_right = "╯",
    horizontal = "─",
    vertical = "│",
  },
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

local function border_hl()
  return vim.fn.hlexists("CommentNvimBorder") == 1 and "CommentNvimBorder" or text_hl()
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text or "")
end

local function pad_right(text, width)
  local padding = width - display_width(text)
  if padding <= 0 then
    return text
  end
  return text .. string.rep(" ", padding)
end

local function trim_empty_edges(lines)
  local first = 1
  local last = #lines

  while first <= last and vim.trim(lines[first]) == "" do
    first = first + 1
  end

  while last >= first and vim.trim(lines[last]) == "" do
    last = last - 1
  end

  local trimmed = {}
  for index = first, last do
    table.insert(trimmed, lines[index])
  end

  return trimmed
end

local function clean_edit_lines(lines)
  local cleaned = {}

  for _, line in ipairs(lines) do
    line = line:gsub("^%s*│%s?", "", 1)
    table.insert(cleaned, line)
  end

  return trim_empty_edges(cleaned)
end

local function split_for_width(text, width)
  if width <= 8 or display_width(text) <= width then
    return { text }
  end

  local chunks = {}
  local current = ""

  for word in tostring(text):gmatch("%S+%s*") do
    local candidate = current .. word
    if current ~= "" and display_width(candidate) > width then
      table.insert(chunks, vim.trim(current))
      current = word
    else
      current = candidate
    end
  end

  if current ~= "" then
    table.insert(chunks, vim.trim(current))
  end

  if #chunks == 0 then
    table.insert(chunks, text)
  end

  return chunks
end

local function render_lines(item, end_line)
  local box = config.box
  local max_width = math.max(config.max_width or 72, 24)
  local label = item.start_line == end_line and tostring(item.start_line)
    or string.format("%d-%d", item.start_line, end_line)
  local title = " comment " .. label .. " "
  local body = {}

  for _, line in ipairs(item.lines or {}) do
    local wrapped = split_for_width(line, max_width)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(body, wrapped_line)
    end
  end

  if #body == 0 then
    table.insert(body, "")
  end

  local width = display_width(title)
  for _, line in ipairs(body) do
    width = math.max(width, display_width(line))
  end
  width = math.min(width, max_width)

  local top_fill = math.max(width - display_width(title), 0)
  local lines = {
    {
      { box.indent .. box.top_left .. box.horizontal .. title .. string.rep(box.horizontal, top_fill) .. box.top_right, border_hl() },
    },
  }

  for _, line in ipairs(body) do
    table.insert(lines, {
      { box.indent .. box.vertical .. " ", border_hl() },
      { pad_right(line, width), text_hl() },
      { " " .. box.vertical, border_hl() },
    })
  end

  table.insert(lines, {
    { box.indent .. box.bottom_left .. string.rep(box.horizontal, width + 2) .. box.bottom_right, border_hl() },
  })

  return lines
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

      vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0, {
        virt_lines = render_lines(item, end_line),
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
  if edit.start_edit_line < 1 or edit.start_edit_line > last_line then
    return
  end

  local end_edit_line = edit.end_edit_line
  for lnum = edit.start_edit_line, last_line do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line == edit.end_marker then
      end_edit_line = lnum
      break
    end
  end

  if end_edit_line and end_edit_line <= last_line then
    vim.api.nvim_buf_set_lines(bufnr, edit.start_edit_line - 1, end_edit_line, false, {})
  end
end

local function finish_edit(bufnr, save)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_state = get_buf_state(bufnr)
  local edit = buf_state.editing

  if not edit then
    return
  end

  local lines = {}
  if vim.api.nvim_buf_is_valid(bufnr) then
    local last_line = vim.api.nvim_buf_line_count(bufnr)
    local end_edit_line = edit.end_edit_line

    for lnum = edit.start_edit_line, last_line do
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
      if line == edit.end_marker then
        end_edit_line = lnum
        break
      end
    end

    if end_edit_line and end_edit_line > edit.start_edit_line + 1 then
      lines = vim.api.nvim_buf_get_lines(bufnr, edit.start_edit_line, end_edit_line - 1, false)
    end
  end

  remove_editing_lines(bufnr, edit)

  if save then
    lines = clean_edit_lines(lines)
    if #lines > 0 then
      table.insert(buf_state.comments, {
        id = buf_state.next_id,
        start_line = edit.start_line,
        end_line = edit.end_line,
        lines = lines,
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
  local range_label = start_line == end_line and tostring(start_line) or string.format("%d-%d", start_line, end_line)
  local start_marker = "╭─ comment.nvim " .. range_label .. " ─╮"
  local body_marker = "│ "
  local end_marker = "╰─ comment.nvim end ─╯"

  vim.api.nvim_buf_set_lines(bufnr, insert_index, insert_index, false, {
    start_marker,
    body_marker,
    end_marker,
  })
  vim.api.nvim_win_set_cursor(0, { insert_line + 1, #body_marker })
  vim.cmd("startinsert!")

  local augroup = vim.api.nvim_create_augroup("CommentNvimEdit" .. bufnr, { clear = true })
  buf_state.editing = {
    augroup = augroup,
    bufnr = bufnr,
    cursor_line = start_line,
    cursor_col = 0,
    end_line = end_line,
    end_edit_line = insert_line + 2,
    end_marker = end_marker,
    start_edit_line = insert_line,
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

  vim.api.nvim_set_hl(0, "CommentNvimBorder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CommentNvimSign", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CommentNvimText", { default = true, link = "Comment" })

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
