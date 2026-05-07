from dataclasses import dataclass, field
from typing import Optional, Dict, Any, List
from enum import Enum, auto

class SymbolKind(Enum):
    FUNCTION = auto()
    PARAM = auto()
    LOCAL = auto()
    TYPE = auto()
    MODULE = auto()
    GLOBAL = auto()

@dataclass
class Symbol:
    name: str
    kind: SymbolKind
    type: Optional[Any] = None
    decl_node: Any = None
    ir_var: Any = None

@dataclass
class Scope:
    parent: Optional['Scope'] = None
    symbols: Dict[str, Symbol] = field(default_factory=dict)

    def define(self, sym: Symbol):
        if sym.name in self.symbols:
            raise NameError(f"Duplicate definition: {sym.name}")
        self.symbols[sym.name] = sym

    def lookup(self, name: str, recursive: bool = True) -> Optional[Symbol]:
        if name in self.symbols:
            return self.symbols[name]
        if recursive and self.parent:
            return self.parent.lookup(name)
        return None

class SymbolTable:
    def __init__(self):
        self.root_scope = Scope()
        self.current_scope = self.root_scope

    def push_scope(self):
        self.current_scope = Scope(parent=self.current_scope)

    def pop_scope(self):
        if self.current_scope.parent:
            self.current_scope = self.current_scope.parent
        else:
            raise RuntimeError("Cannot pop root scope")

    def define(self, name: str, kind: SymbolKind, type_=None, decl=None, ir_var=None):
        sym = Symbol(name, kind, type_, decl, ir_var)
        self.current_scope.define(sym)

    def lookup(self, name: str, recursive: bool = True) -> Optional[Symbol]:
        return self.current_scope.lookup(name, recursive)
