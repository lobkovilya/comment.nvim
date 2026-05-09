# comment.nvim

Ephemeral in-buffer comments for Neovim.

This plugin lets you attach a comment to a single line or visual line range. Comments are rendered in the buffer with signs and virtual lines, can be shown or hidden, and are kept only in memory for the current Neovim session.

Persistence is intentionally not implemented yet.

## Requirements

- Neovim 0.9+
- Pure Lua

## Installation

With lazy.nvim:

```lua
{
  "lobkovilya/comment.nvim",
  config = function()
    require("comment").setup()
  end,
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
```

When adding a comment, `COMMENT: ` is inserted directly below the target line or range. Type the comment there and leave insert mode to save it. Empty comments are ignored.

## Configuration

```lua
require("comment").setup({
  signs = true,
  sign_text = "C",
  virtual_line_prefix = "  comment ",
  mappings = {
    add = "<leader>ca",
    toggle = "<leader>ct",
    delete = "<leader>cd",
  },
})
```

Set `mappings = false` to skip default mappings.
