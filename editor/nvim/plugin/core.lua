-- Core Language IDE Plugin for Neovim
-- Provides diagnostics, goto-definition, hover info, and more.
-- Place in ~/.config/nvim/lua/plugins/core.lua (lazy.nvim will auto-load)

local M = {}

-- ─── Configuration ───────────────────────────────────────────────
local options = {
  -- Path to corec compiler (auto-detected if nil)
  compiler_path = nil,
  -- Use Python bootstrap for diagnostics (more reliable errors)
  use_python = false,
  -- Auto-run diagnostics on save
  auto_diagnose = true,
  -- Keymaps
  keymaps = {
    hover = "K",
    goto_definition = "gd",
    next_error = "]e",
    prev_error = "[e",
  },
}

-- ─── Helpers ─────────────────────────────────────────────────────

local function find_project_root()
  local cwd = vim.fn.getcwd()
  local markers = { "build/corec", "tools/corec", "Core.toml", ".git" }
  local dir = cwd
  for _ = 1, 20 do
    for _, marker in ipairs(markers) do
      local path = dir .. "/" .. marker
      if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
        return dir
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return cwd
end

local function find_compiler(root)
  if options.compiler_path and vim.fn.executable(options.compiler_path) == 1 then
    return options.compiler_path
  end
  local candidates = {
    root .. "/build/corec",
    root .. "/tools/corec",
    vim.fn.exepath("corec"),
  }
  for _, c in ipairs(candidates) do
    if c and vim.fn.filereadable(c) == 1 then
      return c
    end
  end
  return nil
end

-- ─── 1. Diagnostics (on save) ────────────────────────────────────

local function clear_diagnostics(bufnr)
  vim.diagnostic.reset(nil, bufnr or 0)
end

local function run_diagnostics()
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if not filepath:match("%.cr$") then return end

  clear_diagnostics(bufnr)

  local root = find_project_root()
  local compiler = find_compiler(root)

  if not compiler then
    vim.notify("[core] compiler not found", vim.log.levels.WARN)
    return
  end

  local use_python = options.use_python or compiler:match("tools/corec")
  local cmd
  if use_python then
    cmd = { "python3", compiler, "build", filepath, "-o", "/dev/null" }
  else
    cmd = { compiler, "--check", filepath }
  end

  vim.schedule(function()
    local output = vim.fn.system(cmd)
    local rc = vim.v.shell_error

    if rc == 0 then
      vim.diagnostic.reset(nil, bufnr)
      return
    end

    local diagnostics = {}
    -- Parse error format:
    --   error CODE: MESSAGE        → error %d: %s
    --     --> LINE:COL              → multiline continuation
    local lines = vim.split(output, "\n")
    local i = 1
    while i <= #lines do
      local line = lines[i]
      local err_match = line:match("^error (%d+): (.+)$")
      if err_match then
        local code = tonumber(err_match[1]) or err_match[1]
        local msg = err_match[2]
        local lnum = 0
        local col = 0
        -- Next line should have --> LINE:COL
        if i + 1 <= #lines then
          local loc_match = lines[i + 1]:match("%-%-%>%s+(%d+):(%d+)")
          if loc_match then
            lnum = tonumber(loc_match[1]) or 0
            col = tonumber(loc_match[2]) or 0
          end
        end
        table.insert(diagnostics, {
          bufnr = bufnr,
          lnum = math.max(0, lnum - 1),
          col = math.max(0, col - 1),
          message = msg,
          severity = vim.diagnostic.severity.ERROR,
          source = "corec",
          code = tostring(code),
        })
        i = i + 2
      end
      i = i + 1
    end

    if #diagnostics > 0 then
      vim.diagnostic.set(vim.api.nvim_get_current_namespace(), bufnr, diagnostics)
      -- Auto-open quickfix if there are errors
      if vim.g.core_auto_quickfix ~= false then
        local qflist = {}
        for _, d in ipairs(diagnostics) do
          table.insert(qflist, {
            bufnr = d.bufnr,
            lnum = d.lnum + 1,
            col = d.col + 1,
            text = d.message,
            type = "E",
          })
        end
        vim.fn.setqflist(qflist, "r")
        -- Only open if not already visible
        if not vim.tbl_isempty(qflist) then
          vim.cmd("botright copen 6")
        end
      end
    end
  end)
end

-- ─── 2. Hover Info (show type at cursor) ─────────────────────────

local function get_identifier_at_cursor()
  local word = vim.fn.expand("<cword>")
  return word ~= "" and word or nil
end

local function show_hover_info()
  local word = get_identifier_at_cursor()
  if not word then
    vim.notify("[core] no identifier under cursor", vim.log.levels.INFO)
    return
  end

  -- Search declarations in the current file
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Try to find a declaration for this word
  local info_lines = {}
  for i, line in ipairs(lines) do
    -- Match function declarations: fn NAME( or fn NAME<
    local fn_match = line:match("^fn%s+(" .. word .. ")%s*[<(]")
    if fn_match then
      table.insert(info_lines, string.format("  fn declaration at line %d", i))
    end
    -- Match struct/enum declarations
    local decl_match = line:match("^(struct|enum)%s+" .. word .. "%s*[<{]")
    if decl_match then
      table.insert(info_lines, string.format("  %s declaration at line %d", decl_match[1], i))
    end
    -- Match variable declarations: name :=  or name : type
    local var_match = line:match("^%s*" .. word .. "%s*[:=]")
    if var_match then
      local stripped = line:gsub("^%s+", "")
      table.insert(info_lines, string.format("  variable at line %d: %s", i, stripped))
    end
    -- Match let declarations
    local let_match = line:match("%s+" .. word .. "%s*:=[^=]")
    if let_match then
      table.insert(info_lines, string.format("  bound at line %d", i))
    end
  end

  if #info_lines == 0 then
    -- Try grep for broader search
    local root = find_project_root()
    local grep_cmd = string.format("grep -rn '\\b%s\\b' %s/*.cr 2>/dev/null | head -5", word, root .. "/src")
    local grep_out = vim.fn.system(grep_cmd)
    if vim.v.shell_error == 0 and grep_out ~= "" then
      local g_lines = vim.split(grep_out, "\n")
      for _, gl in ipairs(g_lines) do
        if gl ~= "" then
          table.insert(info_lines, "  " .. gl)
        end
      end
    end
  end

  if #info_lines == 0 then
    vim.notify(string.format("[core] no references found for '%s'", word), vim.log.levels.INFO)
  else
    local title = string.format("### Core: `%s`\n", word)
    local body = table.concat(info_lines, "\n")
    vim.lsp.util.open_floating_preview(
      vim.split(title .. body, "\n"),
      "markdown",
      { border = "rounded" }
    )
  end
end

-- ─── 3. Goto Definition ──────────────────────────────────────────

local function goto_definition()
  local word = get_identifier_at_cursor()
  if not word then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Search for the definition: fn NAME, struct NAME, enum NAME, NAME :, NAME :=
  for i, line in ipairs(lines) do
    local def_patterns = {
      "^fn%s+" .. word .. "%s*[<(]",
      "^struct%s+" .. word,
      "^enum%s+" .. word,
      "^%s*" .. word .. "%s*:=",
      "^%s*" .. word .. "%s*:%s",
    }
    for _, pat in ipairs(def_patterns) do
      if line:match(pat) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end

  vim.notify(string.format("[core] definition not found for '%s'", word), vim.log.levels.INFO)
end

-- ─── 4. Run current file ─────────────────────────────────────────

local function run_file()
  local filepath = vim.api.nvim_buf_get_name(0)
  local root = find_project_root()
  local compiler = find_compiler(root)

  if not compiler then
    vim.notify("[core] compiler not found", vim.log.levels.ERROR)
    return
  end

  local cmd = compiler:match("tools/corec")
      and string.format("python3 %s build %s -o /dev/null && echo '--- compile ok ---'", compiler, filepath)
      or string.format("%s --check %s && echo '--- type check ok ---'", compiler, filepath)

  vim.cmd("terminal " .. cmd)
  vim.cmd("startinsert")
end

-- ─── Setup ───────────────────────────────────────────────────────

local function setup(user_opts)
  options = vim.tbl_deep_extend("force", options, user_opts or {})

  local group = vim.api.nvim_create_augroup("core_language", { clear = true })

  -- Auto-diagnostics
  if options.auto_diagnose then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      pattern = { "*.cr", "*.corespec" },
      callback = run_diagnostics,
    })

    -- Also run on BufRead
    vim.api.nvim_create_autocmd("BufRead", {
      group = group,
      pattern = { "*.cr", "*.corespec" },
      callback = function()
        vim.defer_fn(run_diagnostics, 200)
      end,
    })
  end

  -- Keymaps (buffer-local)
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "core", "coreir" },
    callback = function()
      local opts = { buffer = true, silent = true }

      if options.keymaps.hover then
        vim.keymap.set("n", options.keymaps.hover, show_hover_info, vim.tbl_extend("force", opts, {
          desc = "Core: show hover info",
        }))
      end

      if options.keymaps.goto_definition then
        vim.keymap.set("n", options.keymaps.goto_definition, goto_definition, vim.tbl_extend("force", opts, {
          desc = "Core: go to definition",
        }))
      end

      if options.keymaps.next_error then
        vim.keymap.set("n", options.keymaps.next_error, function()
          vim.diagnostic.goto_next({ severity = vim.diagnostic.severity.ERROR })
        end, vim.tbl_extend("force", opts, { desc = "Core: next error" }))
      end

      if options.keymaps.prev_error then
        vim.keymap.set("n", options.keymaps.prev_error, function()
          vim.diagnostic.goto_prev({ severity = vim.diagnostic.severity.ERROR })
        end, vim.tbl_extend("force", opts, { desc = "Core: prev error" }))
      end
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("CoreRun", run_file, { desc = "Run current Core file" })
  vim.api.nvim_create_user_command("CoreType", show_hover_info, { desc = "Show type info at cursor" })
  vim.api.nvim_create_user_command("CoreCheck", run_diagnostics, { desc = "Run Core type checker" })
end

-- 延迟到 VimEnter 后执行 setup（autocmd + keymap + commands）
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.defer_fn(function()
      setup({})
    end, 100)
  end,
})

-- Fix syntax for core/coreir (overrides crystal from Treesitter/builtin)
vim.api.nvim_create_autocmd("BufReadPost", {
  pattern = { "*.cr", "*.corespec", "*.cir", "*.ccr" },
  callback = function(ev)
    local ft = vim.bo[ev.buf].filetype
    if ft == "core" or ft == "coreir" then
      vim.bo[ev.buf].syntax = ft
    end
  end,
})
