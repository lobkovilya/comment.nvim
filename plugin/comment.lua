if vim.g.loaded_comment_nvim == 1 then
  return
end
vim.g.loaded_comment_nvim = 1

require("comment").setup(vim.g.comment_nvim_config or {})
