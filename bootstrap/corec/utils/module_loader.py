"""Module/import resolution for the bootstrap compiler pipeline.

Resolves imports by file identifier (not file path), supports:
  - `import fileid [as alias]`
  - `import @project fileid [as alias]`
  - `fileid "name";` declarations
  - `_import.cr` directory-level batch imports
  - Core.toml project name
"""

import os, re

from corec.syntax.ast import *
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser


# Regex to quickly extract fileid from source without full parse
_FILEID_RE = re.compile(r'^\s*fileid\s+"([^"]+)"', re.MULTILINE)


def _parse_coretoml(search_path):
    """Read Core.toml and return project name, or None."""
    toml_path = os.path.join(search_path, 'Core.toml')
    if not os.path.exists(toml_path):
        return None
    m = re.search(r'^\s*name\s*=\s*"([^"]+)"', open(toml_path).read(), re.MULTILINE)
    return m.group(1) if m else None


def _determine_fileid(filepath):
    """Read a .cr file and determine its file identifier.

    If the file starts with `fileid "name";`, use that.
    Otherwise use the filename without .cr extension.
    """
    with open(filepath) as f:
        head = f.read(512)  # Only need first few hundred bytes
    m = _FILEID_RE.search(head)
    if m:
        return m.group(1)
    return os.path.splitext(os.path.basename(filepath))[0]


def _collect_file_registry(search_paths):
    """Build fileid → filepath mapping and collect _import.cr data.

    Returns:
        (registry, dir_imports)
        - registry: dict[fileid] → filepath
        - dir_imports: dict[dirpath → list of (fileid, alias, project)]
    """
    registry = {}
    dir_imports = {}  # dir → list of (file_id, alias, project)

    for sp in search_paths:
        if not os.path.isdir(sp):
            continue
        # Check for project name in Core.toml
        project_name = _parse_coretoml(sp)

        for root, dirs, files in os.walk(sp):
            # Check for _import.cr in this directory
            if '_import.cr' in files:
                imp_path = os.path.join(root, '_import.cr')
                imports = _parse_imports_from_file(imp_path)
                dir_imports[root] = imports

            for f in files:
                if not f.endswith('.cr') or f == '_import.cr':
                    continue
                filepath = os.path.join(root, f)
                fileid = _determine_fileid(filepath)

                if fileid in registry:
                    raise ValueError(
                        f"Duplicate file identifier '{fileid}' in project '{project_name or 'local'}': "
                        f"{registry[fileid]} and {filepath}"
                    )
                registry[fileid] = filepath

    return registry, dir_imports


def _parse_imports_from_file(filepath):
    """Parse a .cr file and return its import declarations.

    Returns list of (file_id, alias, project).
    """
    with open(filepath) as f:
        src = f.read()
    lex = Lexer(src)
    tokens = lex.tokenize()
    parser = Parser(tokens)
    cu = parser.parse_compilation_unit()
    return [(imp.path[0], imp.alias, imp.project) for imp in cu.imports]


def _apply_dir_imports(dir_path, dir_imports, registry):
    """Get all imports that apply to a file in dir_path, including inherited.

    Walks up directory tree merging _import.cr imports.
    """
    merged = []
    seen = set()
    # Walk from root down to dir_path, collecting _import.cr imports
    # Actually walk all parent dirs from root, merging applicable ones
    # Strategy: collect all _import.cr dirs, then for a given file path,
    # include imports from any ancestor directory.
    dirs_to_check = []
    parent = dir_path
    while True:
        if parent in dir_imports:
            dirs_to_check.append(parent)
        # Linux: parent of / is /
        new_parent = os.path.dirname(parent)
        if new_parent == parent:
            break
        parent = new_parent
    # Apply from root to innermost (closer overrides win for conflicts)
    for d in reversed(dirs_to_check):
        for file_id, alias, project in dir_imports[d]:
            key = (file_id, alias, project)
            if key not in seen:
                seen.add(key)
                merged.append(key)
    return merged


def resolve_imports(ast, source_path=None, search_paths=None, errors=None):
    """Resolve all ImportDecls — flatten imported modules into the AST.

    For each import, looks up the file identifier in the registry,
    parses the file, recursively resolves its imports, and prepends
    its declarations into the main compilation unit.

    Supports _import.cr directory-level imports.

    Args:
        ast: CompilationUnit with ImportDecls to resolve
        source_path: Path to the source .cr file (for dir-aware _import.cr)
        search_paths: Directories to search for .cr files
        errors: List to collect error messages
    """
    if search_paths is None:
        search_paths = ['src/stdlib/', './']
    if errors is None:
        errors = []

    # Early exit if there are no imports to resolve
    if not ast.imports:
        return

    # Normalize search paths relative to project root
    script_dir = os.path.dirname(os.path.abspath(__file__))
    proj_root = os.path.normpath(os.path.join(script_dir, '..', '..', '..'))
    abs_search_paths = []
    for sp in search_paths:
        abs_sp = os.path.normpath(os.path.join(proj_root, sp))
        if os.path.isdir(abs_sp):
            abs_search_paths.append(abs_sp)

    # Build file registry
    registry, dir_imports = _collect_file_registry(abs_search_paths)

    # Determine current file's directory for _import.cr lookup
    current_dir = None
    if source_path:
        current_dir = os.path.dirname(os.path.abspath(source_path))

    # Resolve each import
    loaded = set()
    while ast.imports:
        imp = ast.imports.pop(0)

        # Check for _import.cr inherited imports
        if current_dir and current_dir in dir_imports:
            inherited = _apply_dir_imports(current_dir, dir_imports, registry)
            for file_id, alias, project in inherited:
                # Add inherited imports if not already present
                already = any(
                    i.path[0] == file_id and i.project == project
                    for i in ast.imports
                )
                if not already:
                    ast.imports.append(ImportDecl([file_id], alias, project))
            # One-time: mark dir_imports as consumed
            del dir_imports[current_dir]

        file_id = imp.path[0]
        project = imp.project

        # Resolve file_id to a file path
        if project:
            # Cross-project import — search each search path for the project
            filepath = None
            for sp in abs_search_paths:
                candidate = os.path.join(sp, project, file_id + '.cr')
                if os.path.exists(candidate):
                    filepath = candidate
                    break
            if filepath is None:
                errors.append(
                    f"Module not found: @{project} {file_id} "
                    f"(searched: {', '.join(abs_search_paths)})"
                )
                continue
        else:
            if file_id not in registry:
                errors.append(
                    f"Module not found: '{file_id}' (searched: {', '.join(abs_search_paths)})"
                )
                continue
            filepath = registry[file_id]

        abs_path = os.path.abspath(filepath)
        if abs_path in loaded:
            continue
        loaded.add(abs_path)

        # Parse the imported file
        with open(abs_path) as f:
            src = f.read()
        lex = Lexer(src)
        tokens = lex.tokenize()
        mod_ast = Parser(tokens).parse_compilation_unit()

        # Recursively resolve the module's own imports
        resolve_imports(mod_ast, source_path=abs_path,
                       search_paths=search_paths, errors=errors)

        # Prepend imported declarations
        ast.declarations = list(mod_ast.declarations) + ast.declarations
