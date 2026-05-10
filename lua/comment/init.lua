local M = {}

local ns = vim.api.nvim_create_namespace("comment.nvim")
local edit_ns = vim.api.nvim_create_namespace("comment.nvim.edit")

local default_config = {
  comment_position = "below",
  comment_connector = true,
  comment_marker = "💬",
  right_bezel = true,
  right_bezel_offset = -1,
  signs = true,
  range_highlight = false,
  range_highlight_priority = 180,
  trim_leading_whitespace = true,
  comment_width = 120,
  range_signs = {
    single = "◆",
    top = "╭",
    middle = "│",
    bottom = "╰",
  },
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

local config = vim.deepcopy(default_config)

local state = {
  buffers = {},
  mappings = {},
  user_highlights = {},
}

local default_highlights = {
  CommentNvimBorder = { fg = "#9e917e" },
  CommentNvimRange = { bg = "#4a3728" },
  CommentNvimRangeNumber = { fg = "#ffd166", bg = "#4a3728", bold = true },
  CommentNvimRangeText = { bg = "#5a402d" },
  CommentNvimSign = { link = "Comment" },
  CommentNvimText = { fg = "#b8afa3" },
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

local function remember_user_highlights()
  for group, _ in pairs(default_highlights) do
    state.user_highlights[group] = vim.fn.hlexists(group) == 1
  end
end

local function apply_highlights()
  for group, value in pairs(default_highlights) do
    if not state.user_highlights[group] then
      vim.api.nvim_set_hl(0, group, value)
    end
  end
end

local function sign_hl()
  return vim.fn.hlexists("CommentNvimSign") == 1 and "CommentNvimSign" or "Comment"
end

local function range_hl()
  return vim.fn.hlexists("CommentNvimRange") == 1 and "CommentNvimRange" or nil
end

local function range_number_hl()
  return vim.fn.hlexists("CommentNvimRangeNumber") == 1 and "CommentNvimRangeNumber" or nil
end

local function range_text_hl()
  return vim.fn.hlexists("CommentNvimRangeText") == 1 and "CommentNvimRangeText" or nil
end

local function text_hl()
  return vim.fn.hlexists("CommentNvimText") == 1 and "CommentNvimText" or "Comment"
end

local function border_hl()
  return vim.fn.hlexists("CommentNvimBorder") == 1 and "CommentNvimBorder" or text_hl()
end

local function sign_for_line(start_line, end_line, lnum, continues_to_comment)
  if config.sign_text then
    return config.sign_text
  end

  local signs = config.range_signs or {}
  if continues_to_comment then
    return signs.middle or "│"
  end

  if start_line == end_line then
    return signs.single or "◆"
  end
  if lnum == start_line then
    return signs.top or "╭"
  end
  if lnum == end_line then
    return signs.bottom or "╰"
  end
  return signs.middle or "│"
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text or "")
end

local function comment_width()
  return math.max(config.comment_width or config.max_width or 120, 24)
end

local function comment_content_width()
  return comment_width() - 4
end

local function escape_pattern(text)
  return tostring(text or ""):gsub("([^%w])", "%%%1")
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

local function strip_edit_prefix(line, prefix)
  if prefix and prefix ~= "" then
    line = line:gsub("^%s*" .. escape_pattern(prefix), "", 1)
  end
  return line
end

local function strip_edit_body(line, edit)
  line = strip_edit_prefix(line, edit and edit.marker_prefix)

  if edit and edit.body_prefix_cont and vim.startswith(line, edit.body_prefix_cont) then
    line = line:gsub("^" .. escape_pattern(edit.body_prefix_cont), "", 1)
  elseif edit and edit.body_prefix and edit.body_prefix ~= "" then
    line = line:gsub("^" .. escape_pattern(edit.body_prefix), "", 1)
  else
    line = line:gsub("^%s*│%s?", "", 1)
  end

  if edit and edit.body_suffix and edit.body_suffix ~= "" then
    line = line:gsub("%s*" .. escape_pattern(edit.body_suffix) .. "$", "", 1)
  end

  return line:gsub("%s+$", "")
end

local function clean_edit_lines(lines, edit)
  local cleaned = {}

  for _, line in ipairs(lines) do
    line = strip_edit_body(line, edit)
    if config.trim_leading_whitespace then
      line = line:gsub("^%s+", "", 1)
    end
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
  local width = comment_content_width()
  local title = ""
  local body = {}

  for _, line in ipairs(item.lines or {}) do
    local wrapped = split_for_width(line, width)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(body, wrapped_line)
    end
  end

  if #body == 0 then
    table.insert(body, "")
  end

  width = math.max(width, display_width(title))

  local top_fill = math.max(width + 1 - display_width(title), 0)
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

local function text_offset()
  local ok, info = pcall(vim.fn.getwininfo, vim.api.nvim_get_current_win())
  if ok and info and info[1] and info[1].textoff then
    return info[1].textoff
  end

  return 0
end

local function connected_layout(item, end_line, bufnr)
  local box = config.box
  local offset = math.max(text_offset(), 0)
  local indent_width = display_width(box.indent or "")
  local width = comment_content_width()
  local title = ""
  local body = {}

  for _, line in ipairs(item.lines or {}) do
    local wrapped = split_for_width(line, width)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(body, wrapped_line)
    end
  end

  if #body == 0 then
    table.insert(body, "")
  end

  width = math.max(width, display_width(title))

  local marker = config.comment_marker or ""
  local marker_width = display_width(marker)
  local marker_gap = marker ~= "" and " " or ""
  local marker_gap_width = display_width(marker_gap)
  local content_prefix_width = math.max(offset - marker_width - marker_gap_width, 0)
  local bridge_width = offset - 1
  local top_bridge = string.rep(box.horizontal, bridge_width)
  local total_inner_width = offset + indent_width + width + 2
  local top_fill = math.max(total_inner_width - display_width(title) - display_width(top_bridge), 0)
  local body_width = math.max(total_inner_width - content_prefix_width - marker_width - marker_gap_width, width)

  return {
    body_width = body_width,
    body = body,
    box = box,
    content_prefix_width = content_prefix_width,
    marker = marker,
    marker_gap = marker_gap,
    offset = offset,
    title = title,
    top_bridge = top_bridge,
    top_fill = top_fill,
    total_inner_width = total_inner_width,
    width = width,
    right_border_col = math.max(total_inner_width + 1 - offset + (config.right_bezel_offset or 0), 1),
  }
end

local function add_right_bezel(bufnr, lnum, layout)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local current_width = display_width(line)
  local target_col = layout.right_border_col

  if current_width >= target_col then
    return
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
    virt_text = {
      { string.rep(" ", target_col - current_width), "Normal" },
      { layout.box.vertical or "│", border_hl() },
    },
    virt_text_pos = "eol",
    priority = config.range_highlight_priority,
  })
end

local function connected_top_lines(layout)
  return {
    {
      { layout.box.top_left .. string.rep(layout.box.horizontal, layout.total_inner_width) .. layout.box.top_right, border_hl() },
    },
  }
end

local function connected_render_lines(layout)
  local box = layout.box
  local lines = {
    {
      { box.vertical .. layout.top_bridge .. layout.title .. string.rep(box.horizontal, layout.top_fill) .. "┤", border_hl() },
    },
  }

  for index, line in ipairs(layout.body) do
    local marker = index == 1 and layout.marker or string.rep(" ", display_width(layout.marker))

    table.insert(lines, {
      { box.vertical .. string.rep(" ", math.max(layout.content_prefix_width - 1, 0)), border_hl() },
      { marker, text_hl() },
      { layout.marker_gap, text_hl() },
      { pad_right(line, layout.body_width), text_hl() },
      { " " .. box.vertical, border_hl() },
    })
  end

  table.insert(lines, {
    { box.bottom_left .. string.rep(box.horizontal, layout.total_inner_width) .. box.bottom_right, border_hl() },
  })

  return lines
end

local find_edit_end_line

local function edit_body_prefix(markers, continuation)
  if continuation and markers.body_prefix_cont then
    return markers.body_prefix_cont
  end

  return markers.body_prefix
end

local function edit_body_line(markers, text, continuation)
  return edit_body_prefix(markers, continuation) .. pad_right(text or "", markers.body_width) .. markers.body_suffix
end

local function edit_line_content(line, edit, continuation, cursor_col)
  if not cursor_col then
    return strip_edit_body(line, edit)
  end

  local prefix = edit_body_prefix(edit, continuation)
  local prefix_len = #prefix
  local before = ""
  local after = ""

  if vim.startswith(line, prefix) then
    local content_col = math.max(cursor_col - prefix_len, 0)
    before = line:sub(prefix_len + 1, prefix_len + content_col)
    after = line:sub(prefix_len + content_col + 1)
  else
    before = line:sub(1, cursor_col)
    after = line:sub(cursor_col + 1)
  end

  after = strip_edit_body(prefix .. after, edit)
  return before .. after, #before
end

local function edit_markers(start_line, end_line, bufnr)
  local use_connector = config.comment_connector and config.comment_position == "below"

  if use_connector then
    local layout = connected_layout({
      start_line = start_line,
      end_line = end_line,
      lines = { "" },
    }, end_line, bufnr)

    local marker = layout.marker ~= "" and layout.marker or string.rep(" ", display_width(layout.marker))
    local marker_space = string.rep(" ", display_width(marker))
    local body_prefix = layout.box.vertical .. string.rep(" ", math.max(layout.content_prefix_width - 1, 0)) .. marker .. layout.marker_gap
    local body_prefix_cont = layout.box.vertical .. string.rep(" ", math.max(layout.content_prefix_width - 1, 0)) .. marker_space .. layout.marker_gap
    local body_suffix = " " .. layout.box.vertical
    local inner_width = math.max(layout.total_inner_width, display_width(body_prefix) + display_width(body_suffix))
    local body_width = math.max(inner_width + 2 - display_width(body_prefix) - display_width(body_suffix), 1)

    return {
      start = layout.box.vertical .. layout.top_bridge .. layout.title .. string.rep(layout.box.horizontal, math.max(inner_width - display_width(layout.top_bridge) - display_width(layout.title), 0)) .. "┤",
      body_prefix = body_prefix,
      body_prefix_cont = body_prefix_cont,
      body_suffix = body_suffix,
      body_width = body_width,
      edit_inner_width = inner_width,
      edit_right_border_col = math.max(inner_width - layout.offset, 1),
      finish = layout.box.bottom_left .. string.rep(layout.box.horizontal, inner_width) .. layout.box.bottom_right,
      float = true,
      layout = layout,
      marker_prefix = "",
    }
  end

  local box = config.box
  local width = comment_content_width()

  return {
    start = box.indent .. box.top_left .. string.rep(box.horizontal, width + 2) .. box.top_right,
    body_prefix = box.indent .. box.vertical .. " ",
    body_suffix = " " .. box.vertical,
    body_width = width,
    finish = box.indent .. box.bottom_left .. string.rep(box.horizontal, width + 2) .. box.bottom_right,
    marker_prefix = "",
  }
end

local function render_edit_context(bufnr, start_line, end_line, markers, frame_only)
  local layout = markers and markers.layout
  if not layout then
    return
  end

  local edit_height = markers.edit_height or 3
  local spacer_lines = {}
  for _ = 1, edit_height do
    table.insert(spacer_lines, { { "", "Normal" } })
  end

  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, start_line - 1, 0, {
    virt_lines = {
      {
        {
          layout.box.top_left
            .. string.rep(layout.box.horizontal, markers.edit_inner_width or layout.total_inner_width)
            .. layout.box.top_right,
          border_hl(),
        },
      },
    },
    virt_lines_above = true,
    virt_lines_leftcol = true,
    right_gravity = false,
  })

  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, end_line - 1, 0, {
    virt_lines = spacer_lines,
    virt_lines_leftcol = true,
    right_gravity = false,
  })

  if frame_only or (not config.signs and not config.range_highlight) then
    return
  end

  for lnum = start_line, end_line do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local opts = {}

    if config.signs then
      opts.sign_text = sign_for_line(start_line, end_line, lnum, true)
      opts.sign_hl_group = sign_hl()
    end

    if config.range_highlight then
      opts.line_hl_group = range_hl()
      opts.number_hl_group = range_number_hl()
      opts.priority = config.range_highlight_priority
    end

    if opts.sign_text or opts.line_hl_group then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, opts)
    end

    if config.signs and config.right_bezel then
      add_right_bezel(bufnr, lnum, {
        box = layout.box,
        right_border_col = markers.edit_right_border_col or layout.right_border_col,
      })
    end

    if config.range_highlight and line ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        end_col = #line,
        hl_eol = true,
        hl_group = range_text_hl(),
        priority = config.range_highlight_priority,
      })
    end
  end
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

      local anchor_line = config.comment_position == "below" and end_line or item.start_line
      local lines = render_lines(item, end_line)
      local use_connector = config.comment_connector and config.comment_position == "below"
      local connector_layout = use_connector and connected_layout(item, end_line, bufnr) or nil

      if use_connector then
        vim.api.nvim_buf_set_extmark(bufnr, ns, item.start_line - 1, 0, {
          virt_lines = connected_top_lines(connector_layout),
          virt_lines_above = true,
          virt_lines_leftcol = true,
          right_gravity = false,
        })
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line - 1, 0, {
        virt_lines = use_connector and connected_render_lines(connector_layout) or lines,
        virt_lines_above = config.comment_position ~= "below",
        virt_lines_leftcol = use_connector,
        right_gravity = false,
      })

      if config.signs then
        for lnum = item.start_line, end_line do
          local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
          local opts = {
            sign_text = sign_for_line(item.start_line, end_line, lnum, use_connector),
            sign_hl_group = sign_hl(),
          }

          if config.range_highlight then
            opts.line_hl_group = range_hl()
            opts.number_hl_group = range_number_hl()
            opts.priority = config.range_highlight_priority
          end

          vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, opts)

          if use_connector and config.right_bezel and connector_layout then
            add_right_bezel(bufnr, lnum, connector_layout)
          end

          if config.range_highlight and line ~= "" then
            vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
              end_col = #line,
              hl_eol = true,
              hl_group = range_text_hl(),
              priority = config.range_highlight_priority,
            })
          end
        end
      elseif config.range_highlight then
        for lnum = item.start_line, end_line do
          local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
          vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
            line_hl_group = range_hl(),
            number_hl_group = range_number_hl(),
            priority = config.range_highlight_priority,
          })

          if line ~= "" then
            vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
              end_col = #line,
              hl_eol = true,
              hl_group = range_text_hl(),
              priority = config.range_highlight_priority,
            })
          end
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

  if edit.float then
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

find_edit_end_line = function(bufnr, edit)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local start_edit_line = edit.float and 1 or edit.start_edit_line

  for lnum = start_edit_line, last_line do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line == edit.end_marker then
      return lnum
    end
  end

  return edit.float and math.min(3, last_line) or edit.end_edit_line
end

local function resize_edit_float(edit, edit_bufnr)
  if not edit.float_winid or not vim.api.nvim_win_is_valid(edit.float_winid) then
    return
  end

  edit.edit_height = vim.api.nvim_buf_line_count(edit_bufnr)
  vim.api.nvim_win_set_height(edit.float_winid, edit.edit_height)
  vim.api.nvim_buf_clear_namespace(edit.bufnr, edit_ns, 0, -1)
  render_edit_context(edit.bufnr, edit.start_line, edit.end_line, edit, true)
end

local function insert_edit_newline(bufnr)
  local buf_state = get_buf_state(bufnr)
  local edit = buf_state.editing
  if not edit then
    return
  end

  local edit_bufnr = edit.float_bufnr or bufnr
  local winid = edit.winid
  if not vim.api.nvim_buf_is_valid(edit_bufnr) or not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local lnum = cursor[1]
  local start_edit_line = edit.float and 1 or edit.start_edit_line
  local end_edit_line = find_edit_end_line(edit_bufnr, edit)
  if lnum <= start_edit_line or lnum >= end_edit_line then
    return
  end

  local continuation = lnum > start_edit_line + 1
  local line = vim.api.nvim_buf_get_lines(edit_bufnr, lnum - 1, lnum, false)[1] or ""
  local content, content_col = edit_line_content(line, edit, continuation, cursor[2])

  local before = content:sub(1, content_col)
  local after = content:sub(content_col + 1)
  vim.api.nvim_buf_set_lines(edit_bufnr, lnum - 1, lnum, false, { edit_body_line(edit, before, continuation) })
  vim.api.nvim_buf_set_lines(edit_bufnr, lnum, lnum, false, { edit_body_line(edit, after, true) })

  if not edit.float then
    edit.end_edit_line = edit.end_edit_line + 1
  end

  resize_edit_float(edit, edit_bufnr)
  vim.api.nvim_win_set_cursor(winid, { lnum + 1, #edit_body_prefix(edit, true) })
end

local function normalize_edit_text(line, edit, continuation, cursor_col)
  local cursor_content_col
  line, cursor_content_col = edit_line_content(line, edit, continuation, cursor_col)
  if config.trim_leading_whitespace then
    local old_len = #line
    line = line:gsub("^%s+", "", 1)
    if cursor_content_col then
      cursor_content_col = math.max(cursor_content_col - (old_len - #line), 0)
    end
  end
  return edit_body_line(edit, line, continuation), cursor_content_col
end

local function normalize_edit_block(bufnr)
  local buf_state = get_buf_state(bufnr)
  local edit = buf_state.editing

  if not edit or edit.normalizing or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local edit_bufnr = edit.float_bufnr or bufnr
  if not vim.api.nvim_buf_is_valid(edit_bufnr) then
    return
  end

  local end_edit_line = find_edit_end_line(edit_bufnr, edit)
  local start_edit_line = edit.float and 1 or edit.start_edit_line
  if not end_edit_line or end_edit_line <= start_edit_line + 1 then
    return
  end

  edit.normalizing = true

  local winid = edit.winid
  local cursor = winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_cursor(winid) or nil
  local changed_cursor_line = false
  local cursor_content_col

  for lnum = start_edit_line + 1, end_edit_line - 1 do
    local line = vim.api.nvim_buf_get_lines(edit_bufnr, lnum - 1, lnum, false)[1] or ""
    local continuation = lnum > start_edit_line + 1
    local normalized, line_cursor_content_col =
      normalize_edit_text(line, edit, continuation, cursor and cursor[1] == lnum and cursor[2] or nil)

    if line ~= normalized then
      vim.api.nvim_buf_set_lines(edit_bufnr, lnum - 1, lnum, false, { normalized })

      if cursor and cursor[1] == lnum then
        changed_cursor_line = true
        cursor_content_col = line_cursor_content_col
      end
    end
  end

  if cursor and changed_cursor_line and vim.api.nvim_win_is_valid(winid) then
    local line = vim.api.nvim_buf_get_lines(edit_bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
    local col = #edit_body_prefix(edit, cursor[1] > start_edit_line + 1) + (cursor_content_col or 0)
    col = math.min(col, #line)
    vim.api.nvim_win_set_cursor(winid, { cursor[1], col })
  end

  resize_edit_float(edit, edit_bufnr)
  edit.normalizing = false
end

local function remove_edit_keymaps(bufnr, edit)
  if not edit or not edit.keymaps then
    return
  end

  for _, lhs in ipairs(edit.keymaps) do
    pcall(vim.keymap.del, "i", lhs, { buffer = edit.keymap_bufnr or bufnr })
  end
end

local function remove_mappings()
  for _, mapping in ipairs(state.mappings) do
    pcall(vim.keymap.del, mapping.mode, mapping.lhs)
  end
  state.mappings = {}
end

local function apply_mappings()
  remove_mappings()

  if not config.mappings then
    return
  end

  local mappings = {
    { mode = "n", lhs = config.mappings.add, rhs = M.add_line, desc = "Add comment to line" },
    { mode = "x", lhs = config.mappings.add, rhs = M.add_visual, desc = "Add comment to selection" },
    { mode = "n", lhs = config.mappings.toggle, rhs = M.toggle, desc = "Toggle comments" },
    { mode = "n", lhs = config.mappings.delete, rhs = M.delete_at_cursor, desc = "Delete comment at cursor" },
  }

  for _, mapping in ipairs(mappings) do
    if mapping.lhs then
      vim.keymap.set(mapping.mode, mapping.lhs, mapping.rhs, { desc = mapping.desc })
      table.insert(state.mappings, { mode = mapping.mode, lhs = mapping.lhs })
    end
  end
end

local function restore_edit_options(bufnr, edit)
  if not edit or not edit.options then
    return
  end

  for name, value in pairs(edit.options) do
    pcall(vim.api.nvim_set_option_value, name, value, { buf = bufnr })
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
    normalize_edit_block(bufnr)

    local edit_bufnr = edit.float_bufnr or bufnr
    local end_edit_line = vim.api.nvim_buf_is_valid(edit_bufnr) and find_edit_end_line(edit_bufnr, edit) or nil

    local start_edit_line = edit.float and 1 or edit.start_edit_line
    if end_edit_line and end_edit_line > start_edit_line + 1 then
      lines = vim.api.nvim_buf_get_lines(edit_bufnr, start_edit_line, end_edit_line - 1, false)
    end
  end

  if edit.float_winid and vim.api.nvim_win_is_valid(edit.float_winid) then
    pcall(vim.api.nvim_win_close, edit.float_winid, true)
  end
  if edit.float_bufnr and vim.api.nvim_buf_is_valid(edit.float_bufnr) then
    pcall(vim.api.nvim_buf_delete, edit.float_bufnr, { force = true })
  end

  remove_editing_lines(bufnr, edit)
  remove_edit_keymaps(bufnr, edit)
  restore_edit_options(bufnr, edit)
  vim.api.nvim_buf_clear_namespace(bufnr, edit_ns, 0, -1)

  if save then
    lines = clean_edit_lines(lines, edit)
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
  local markers = edit_markers(start_line, end_line, bufnr)
  local edit_bufnr = bufnr
  local edit_winid = vim.api.nvim_get_current_win()
  local keymap_bufnr = bufnr
  local rendered_edit_context = false
  local edit_options = {
    autoindent = vim.api.nvim_get_option_value("autoindent", { buf = bufnr }),
    cindent = vim.api.nvim_get_option_value("cindent", { buf = bufnr }),
    indentexpr = vim.api.nvim_get_option_value("indentexpr", { buf = bufnr }),
    smartindent = vim.api.nvim_get_option_value("smartindent", { buf = bufnr }),
  }

  if not markers.float then
    vim.api.nvim_buf_set_lines(bufnr, insert_index, insert_index, false, {
      markers.start,
      edit_body_line(markers, ""),
      markers.finish,
    })
  end

  vim.api.nvim_set_option_value("autoindent", false, { buf = bufnr })
  vim.api.nvim_set_option_value("cindent", false, { buf = bufnr })
  vim.api.nvim_set_option_value("indentexpr", "", { buf = bufnr })
  vim.api.nvim_set_option_value("smartindent", false, { buf = bufnr })

  if markers.float then
    render_edit_context(bufnr, start_line, end_line, markers)
    rendered_edit_context = true

    edit_bufnr = vim.api.nvim_create_buf(false, true)
    keymap_bufnr = edit_bufnr
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = edit_bufnr })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = edit_bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = edit_bufnr })
    vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, {
      markers.start,
      edit_body_line(markers, ""),
      markers.finish,
    })

    local screenpos = vim.fn.screenpos(0, end_line, 1)
    local row = math.max(screenpos and screenpos.row or 1, 0)
    edit_winid = vim.api.nvim_open_win(edit_bufnr, true, {
      relative = "win",
      win = vim.api.nvim_get_current_win(),
      row = row,
      col = 0,
      width = display_width(markers.finish),
      height = 3,
      style = "minimal",
      border = "none",
      focusable = true,
      noautocmd = true,
    })
    vim.api.nvim_win_set_cursor(edit_winid, { 2, #markers.body_prefix })
  else
    vim.api.nvim_win_set_cursor(0, { insert_line + 1, #markers.body_prefix })
  end
  vim.cmd("startinsert")

  local augroup = vim.api.nvim_create_augroup("CommentNvimEdit" .. bufnr, { clear = true })
  buf_state.editing = {
    augroup = augroup,
    bufnr = bufnr,
    cursor_line = start_line,
    cursor_col = 0,
    end_line = end_line,
    end_edit_line = insert_line + 2,
    end_marker = markers.finish,
    float = markers.float,
    float_bufnr = markers.float and edit_bufnr or nil,
    float_winid = markers.float and edit_winid or nil,
    body_prefix = markers.body_prefix,
    body_prefix_cont = markers.body_prefix_cont,
    body_suffix = markers.body_suffix,
    body_width = markers.body_width,
    edit_height = 3,
    edit_inner_width = markers.edit_inner_width,
    edit_right_border_col = markers.edit_right_border_col,
    layout = markers.layout,
    keymaps = { "<CR>", "<S-CR>" },
    keymap_bufnr = keymap_bufnr,
    marker_prefix = markers.marker_prefix,
    options = edit_options,
    start_edit_line = insert_line,
    start_line = start_line,
    winid = edit_winid,
  }

  if not rendered_edit_context then
    render_edit_context(bufnr, start_line, end_line, markers)
  end

  for _, lhs in ipairs({ "<CR>", "<S-CR>" }) do
    vim.keymap.set("i", lhs, function()
      insert_edit_newline(bufnr)
    end, {
      buffer = keymap_bufnr,
      desc = "Add aligned comment line",
    })
  end

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = augroup,
    buffer = keymap_bufnr,
    callback = function()
      normalize_edit_block(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    buffer = keymap_bufnr,
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
  local mode = vim.fn.mode()
  local start_line
  local end_line

  if mode == "v" or mode == "V" or mode == "\22" then
    start_line = vim.fn.line("v")
    end_line = vim.fn.line(".")
  else
    start_line = vim.fn.line("'<")
    end_line = vim.fn.line("'>")
  end

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.schedule(function()
    M.add_range(start_line, end_line)
  end)
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
  remove_edit_keymaps(bufnr, buf_state.editing)
  buf_state.comments = {}
  buf_state.editing = nil
  render(bufnr)
end

function M.debug()
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local range_marks = 0
  local text_marks = 0

  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.line_hl_group == "CommentNvimRange" then
      range_marks = range_marks + 1
    end
    if details.hl_group == "CommentNvimRangeText" then
      text_marks = text_marks + 1
    end
  end

  vim.notify(
    string.format(
      "comment.nvim range=%s range_hl=%s range_text_hl=%s range_marks=%d text_marks=%d",
      tostring(config.range_highlight),
      vim.inspect(vim.api.nvim_get_hl(0, { name = "CommentNvimRange" })),
      vim.inspect(vim.api.nvim_get_hl(0, { name = "CommentNvimRangeText" })),
      range_marks,
      text_marks
    ),
    vim.log.levels.INFO
  )
end

function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts or {})
  if opts.comment_width == nil and opts.max_width ~= nil then
    config.comment_width = opts.max_width
  end

  remember_user_highlights()
  apply_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CommentNvimHighlights", { clear = true }),
    callback = function()
      apply_highlights()
      for bufnr, _ in pairs(state.buffers) do
        render(bufnr)
      end
    end,
  })

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

  vim.api.nvim_create_user_command("CommentDebug", function()
    M.debug()
  end, {})

  apply_mappings()
end

return M
