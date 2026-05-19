"""Module/import resolution for the bootstrap compiler pipeline.

Resolves `import path.to.module;` declarations by finding, parsing, and
flattening imported .core files into the main compilation unit.
"""

import os

from corec.syntax.ast import *
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser


def resolve_imports(ast: CompilationUnit, search_paths=None, loaded=None, errors=None):
    """Resolve all ImportDecls — flatten imported modules into the AST.

    For each import, searches search_paths for a matching .core file,
    parses it, recursively resolves its imports, and prepends its
    declarations into the main compilation unit.

    search_paths default to ['src/stdlib/', './'] (project-root relative).
    """
    if search_paths is None:
        search_paths = ['src/stdlib/', './']
    if loaded is None:
        loaded = set()
    if errors is None:
        errors = []

    # Determine project root: walk up from this file to find repo root
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # bootstrap/corec/utils/ -> ../../.. = project root
    proj_root = os.path.normpath(os.path.join(script_dir, '..', '..', '..'))

    while ast.imports:
        imp = ast.imports.pop(0)
        # Build file-path candidates: "import io" -> io.core, "import foo.bar" -> foo/bar.core
        rel = os.path.join(*imp.path)
        candidates = []
        for sp in search_paths:
            full = os.path.normpath(os.path.join(proj_root, sp, rel + '.core'))
            candidates.append(full)

        mod_ast = None
        for candidate in candidates:
            if not os.path.exists(candidate):
                continue
            abs_path = os.path.abspath(candidate)
            if abs_path in loaded:
                # Already loaded — break so we don't load twice, but
                # skip the candidate check (we found it)
                mod_ast = None
                break
            loaded.add(abs_path)
            with open(candidate) as f:
                src = f.read()
            lex = Lexer(src)
            tokens = lex.tokenize()
            mod_ast = Parser(tokens).parse_compilation_unit()
            # Recursively resolve the module's own imports
            resolve_imports(mod_ast, search_paths, loaded, errors)
            break

        if mod_ast is None:
            errors.append(f"Module not found: {'::'.join(imp.path)} (searched: {', '.join(candidates)})")
            continue

        # Prepend imported declarations so they are processed first by
        # subsequent pipeline stages (NameResolver, TypeChecker).
        ast.declarations = list(mod_ast.declarations) + ast.declarations
