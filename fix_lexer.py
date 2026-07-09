import re

with open("src/compiler/lexer.cr", "r") as f:
    content = f.read()

# 1: Change function signatures to add src parameter
content = re.sub(
    r'fn cur_char_at\(pos: int, max_len: int\) -> int \{',
    r'fn cur_char_at(src: string, pos: int, max_len: int) -> int {',
    content
)
content = re.sub(
    r'fn peek_at\(pos: int, max_len: int\) -> int \{',
    r'fn peek_at(src: string, pos: int, max_len: int) -> int {',
    content
)
content = re.sub(
    r'fn skip_ws\(pos: int, max_len: int\) -> int \{',
    r'fn skip_ws(src: string, pos: int, max_len: int) -> int {',
    content
)

# 2: Fix load8 in cur_char/peek_at
content = content.replace(
    'return load8(g_source, pos);',
    'return load8(src, pos);'
)
content = content.replace(
    'return load8(g_source, pos + 1);',
    'return load8(src, pos + 1);'
)
# Fix skip_ws internal cur_char_at call
content = content.replace('cur_char_at(pos, max_len)', 'cur_char_at(src, pos, max_len)')

# 3: Fix all cur_char_at/peek_at/skip_ws calls to pass _src
content = re.sub(r'cur_char_at\(([^,]+), _slen\)', r'cur_char_at(_src, \1, _slen)', content)
content = re.sub(r'peek_at\(([^,]+), _slen\)', r'peek_at(_src, \1, _slen)', content)
content = re.sub(r'skip_ws\(([^,)]+), _slen\)', r'skip_ws(_src, \1, _slen)', content)

# 4: In tokenize, replace g_source usage
# Add _src local, fix str_len and str_sub
content = content.replace(
    '_slen : ., mut = str_len(g_source);',
    '_src : ., mut = g_source;\n    _slen : ., mut = str_len(_src);'
)
content = re.sub(r'str_sub\(g_source,', r'str_sub(_src,', content)

with open("src/compiler/lexer.cr", "w") as f:
    f.write(content)

print("Done")
