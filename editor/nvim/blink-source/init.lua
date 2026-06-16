-- blink.cmp source for Core programming language
-- Provides keyword, type, and builtin completions.

local keyword_completions = {
  { label = "fn",         kind = "Keyword", detail = "fn name(params) -> Type { }" },
  { label = "if",         kind = "Keyword", detail = "if cond { }" },
  { label = "else",       kind = "Keyword", detail = "else { }" },
  { label = "match",      kind = "Keyword", detail = "match expr { }" },
  { label = "for",        kind = "Keyword", detail = "for var in iter { }" },
  { label = "while",      kind = "Keyword", detail = "while cond { }" },
  { label = "loop",       kind = "Keyword", detail = "loop { }" },
  { label = "return",     kind = "Keyword", detail = "return expr" },
  { label = "break",      kind = "Keyword", detail = "break" },
  { label = "continue",   kind = "Keyword", detail = "continue" },
  { label = "in",         kind = "Keyword", detail = "for x in iter" },
  { label = "struct",     kind = "Keyword", detail = "struct Name { }" },
  { label = "enum",       kind = "Keyword", detail = "enum Name { Variant, }" },
  { label = "impl",       kind = "Keyword", detail = "impl Type { fn }" },
  { label = "interface",  kind = "Keyword", detail = "interface Name { }" },
  { label = "type",       kind = "Keyword", detail = "type Alias = Type" },
  { label = "mut",        kind = "Keyword", detail = "mutable modifier" },
  { label = "pub",        kind = "Keyword", detail = "public modifier" },
  { label = "mod",        kind = "Keyword", detail = "module declaration" },
  { label = "import",     kind = "Keyword", detail = "import module" },
  { label = "fileid",     kind = "Keyword", detail = 'fileid "name"' },
  { label = "as",         kind = "Keyword", detail = "import mod : alias" },
  { label = "auto",       kind = "Keyword", detail = "auto type inference" },
  { label = "move",       kind = "Keyword", detail = "move ownership" },
  { label = "unsafe",     kind = "Keyword", detail = "unsafe block" },
  { label = "go",         kind = "Keyword", detail = "spawn goroutine" },
  { label = "await",      kind = "Keyword", detail = "await goroutine" },
  { label = "self",       kind = "Keyword", detail = "self parameter" },
  { label = "int",        kind = "Type",    detail = "signed integer" },
  { label = "float",      kind = "Type",    detail = "floating point" },
  { label = "bool",       kind = "Type",    detail = "boolean" },
  { label = "string",     kind = "Type",    detail = "string" },
  { label = "char",       kind = "Type",    detail = "character" },
  { label = "unit",       kind = "Type",    detail = "unit type" },
  { label = "never",      kind = "Type",    detail = "never type" },
  { label = "Self",       kind = "Type",    detail = "Self type in impl" },
  { label = "true",       kind = "Constant", detail = "boolean true" },
  { label = "false",      kind = "Constant", detail = "boolean false" },
  { label = "None",       kind = "Constant", detail = "Option::None" },
  { label = "Some",       kind = "Constant", detail = "Option::Some(value)" },
}

local M = {}

function M.get_completions()
  local items = {}
  local CompletionItemKind = require("blink.cmp.types").CompletionItemKind
  for _, comp in ipairs(keyword_completions) do
    table.insert(items, {
      label = comp.label,
      kind = CompletionItemKind[comp.kind],
      detail = comp.detail,
    })
  end
  return { items = items, is_incomplete_forward = false }
end

return M
