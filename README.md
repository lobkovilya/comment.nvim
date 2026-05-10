# comment.nvim

Ephemeral in-buffer comments for Neovim.

This plugin lets you attach a multi-line comment to a single line or visual line range. Comments are rendered in the buffer with a subtle covered-line tint, a quiet sign-column range bracket, and a muted virtual-line bezel. They can be shown or hidden, and are kept only in memory for the current Neovim session.

Persistence is intentionally not implemented yet.

## Requirements

- Neovim 0.9+
- Pure Lua

## Installation

With lazy.nvim:

```lua
{
  "lobkovilya/comment.nvim",
  main = "comment",
  opts = {},
}
```

For lazy-loading from your main plugin setup:

```lua
{
  "lobkovilya/comment.nvim",
  main = "comment",
  cmd = {
    "CommentAdd",
    "CommentAddRange",
    "CommentToggle",
    "CommentShow",
    "CommentHide",
    "CommentDelete",
    "CommentClear",
    "CommentDebug",
  },
  keys = {
    { "<leader>ma", function() require("comment").add_line() end, desc = "Add comment" },
    { "<leader>ma", function() require("comment").add_visual() end, mode = "x", desc = "Add comment to selection" },
    { "<leader>mt", function() require("comment").toggle() end, desc = "Toggle comments" },
    { "<leader>md", function() require("comment").delete_at_cursor() end, desc = "Delete comment at cursor" },
  },
  opts = {
    mappings = false,
  },
}
```

## Usage

Default mappings:

| Mapping | Mode | Action |
| --- | --- | --- |
| `<leader>ca` | Normal | Add a comment to the current line |
| `<leader>ca` | Visual | Add a comment to the selected line range |
| `<leader>ct` | Normal | Toggle all comments in the current buffer |
| `<leader>cd` | Normal | Delete a comment touching the cursor line |

Commands:

```vim
:CommentAdd
:CommentAddRange
:CommentToggle
:CommentShow
:CommentHide
:CommentDelete
:CommentClear
:CommentDebug
```

When adding a comment, an editable block is inserted directly below the target line or range using the same shape as the rendered comment:

```text
╭────────────────────────╮
│  💬                    │
╰────────────────────────╯
```

Type one or more lines between the top and bottom markers, then leave insert mode to save it. Empty comments are ignored. The editable block is removed from the file and replaced with virtual-line rendering.

## Configuration

```lua
require("comment").setup({
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
})
```

Set `mappings = false` to skip default mappings.

Highlight groups:

```vim
CommentNvimBorder
CommentNvimRange
CommentNvimRangeNumber
CommentNvimRangeText
CommentNvimSign
CommentNvimText
```

The built-in highlight defaults are re-applied after `ColorScheme` changes. Define any of these groups before calling `setup()` to take ownership of that group yourself.
