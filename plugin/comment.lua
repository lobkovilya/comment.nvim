if vim.g.loaded_comment_nvim == 1 then
  return
end
vim.g.loaded_comment_nvim = 1

local lazy_loaded = vim.g.lazy_did_setup == true or vim.g.lazy_did_setup == 1 or package.loaded.lazy ~= nil

if vim.g.comment_nvim_config or not lazy_loaded then
  require("comment").setup(vim.g.comment_nvim_config or {})
end
