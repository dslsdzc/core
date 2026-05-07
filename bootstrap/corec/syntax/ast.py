from dataclasses import dataclass, field
from typing import Optional, List

@dataclass
class Type: pass
@dataclass
class BaseType(Type): name: str
@dataclass
class PathType(Type): path: List[str]
@dataclass
class RefType(Type): mutable: bool; inner: Type
@dataclass
class OptionalType(Type): inner: Type
@dataclass
class TupleType(Type): types: List[Type]
@dataclass
class ArrayType(Type): inner: Type; size: int
@dataclass
class SliceType(Type): inner: Type
@dataclass
class GenericApplyType(Type): path: List[str]; args: List[Type]
@dataclass
class Expr: pass
@dataclass
class Literal(Expr): value: object; kind: str
@dataclass
class Ident(Expr): name: str
@dataclass
class BinaryOp(Expr): left: Expr; op: str; right: Expr
@dataclass
class UnaryOp(Expr): op: str; operand: Expr
@dataclass
class Call(Expr): func: Expr; args: List[Expr]
@dataclass
class FieldAccess(Expr): object: Expr; field: str
@dataclass
class Index(Expr): object: Expr; index: Expr
@dataclass
class Try(Expr): expr: Expr
@dataclass
class ArrayLit(Expr):
    elements: List[Expr]
    element_type: Optional[Type] = None

@dataclass
class StructLit(Expr): path: List[str]; fields: List[tuple]
@dataclass
class EnumConstructor(Expr): path: List[str]; args: List[Expr]
@dataclass
class Block(Expr): stmts: List['Stmt']; expr: Optional[Expr] = None
@dataclass
class If(Expr): cond: Expr; then_branch: Block; else_branch: Optional[Expr] = None
@dataclass
class Match(Expr): expr: Expr; arms: List['MatchArm']
@dataclass
class MatchArm: pattern: 'Pattern'; body: Expr
@dataclass
class RangeExpr(Expr): start: Expr; end: Expr
@dataclass
class Loop(Expr): block: Block
@dataclass
class For(Expr): var: str; iter: Expr; block: Block
@dataclass
class Go(Expr): expr: Expr
@dataclass
class Await(Expr): expr: Expr
@dataclass
class Unsafe(Expr): block: Block
@dataclass
class Flow(Expr): block: Block
@dataclass
class Yield(Expr): expr: Expr
@dataclass
class Recv(Expr): expr: Expr
@dataclass
class Pattern: pass
@dataclass
class Wildcard(Pattern): pass
@dataclass
class LiteralPattern(Pattern): lit: Literal
@dataclass
class IdentPattern(Pattern): name: str
@dataclass
class TuplePattern(Pattern): patterns: List[Pattern]
@dataclass
class StructPattern(Pattern): path: List[str]; fields: List[tuple]
@dataclass
class EnumPattern(Pattern): path: List[str]; args: Optional[List[Pattern]] = None
@dataclass
class Stmt: pass
@dataclass
class LetStmt(Stmt): mutable: bool; name: str; type_: Optional[Type] = None; value: Optional[Expr] = None
@dataclass
class ExprStmt(Stmt): expr: Expr
@dataclass
class ReturnStmt(Stmt): value: Optional[Expr] = None
@dataclass
class BreakStmt(Stmt): pass
@dataclass
class ContinueStmt(Stmt): pass
@dataclass
class Decl: pass
@dataclass
class FunctionDecl(Decl): public: bool; name: str; generics: List[str]; params: List[tuple]; return_type: Type; body: Optional[Expr] = None; specs: Optional[List] = None
@dataclass
class StructDecl(Decl): public: bool; name: str; generics: List[str]; fields: List[tuple]
@dataclass
class EnumDecl(Decl): public: bool; name: str; generics: List[str]; variants: List[tuple]
@dataclass
class InterfaceDecl(Decl): public: bool; name: str; generics: List[str]; methods: List[tuple]
@dataclass
class ImplDecl(Decl): generics: List[str]; trait: Optional[List[str]]; for_type: List[str]; methods: List[FunctionDecl]
@dataclass
class TypeAliasDecl(Decl): name: str; type_: Type
@dataclass
class ModuleDecl(Decl): path: List[str]
@dataclass
class LetDecl(Decl):
    mutable: bool
    name: str
    type_: Optional[Type] = None
    value: Optional[Expr] = None
@dataclass
class ImportDecl(Decl): path: List[str]; alias: Optional[str] = None
@dataclass
@dataclass
class CompilationUnit: modules: List[ModuleDecl]; imports: List[ImportDecl]; declarations: List[Decl]
