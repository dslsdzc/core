"""
Core IR (.cir) — Dataflow graph IR.

The dataflow graph is the core semantic representation of a Core program.
Each node carries complete type and operation info so that a formal verifier
can reconstruct the program's meaning from the graph alone — no source, no
backend IR knowledge required.

Node types (self.kind):
  const, binary, unary, call, return,
  alloc, alloc_struct, alloc_array,
  load, store, load_field, store_field,
  load_index, store_index, load_index_var, store_index_var,
  load_enum_tag, make_enum,
  ref, deref, branch, jump, label, phi, slice

Each node has a `semantics` dict with operation-specific fields
(see extract_graph() for the full field set per kind).
"""

from corec.ir.coreir import (
    Module, FunctionDef, BasicBlock,
    ConstInstr, BinaryInstr, UnaryInstr, CallInstr, ReturnInstr,
    AllocInstr, AllocStructInstr, AllocArrayInstr,
    LoadInstr, StoreInstr,
    LoadFieldInstr, StoreFieldInstr,
    LoadIndexInstr, StoreIndexInstr,
    LoadIndexVarInstr, StoreIndexVarInstr,
    LoadEnumTagInstr, MakeEnumInstr,
    RefInstr, BranchInstr, JumpInstr, LabelInstr, PhiInstr,
)
from corec.ir.base import IRVar


class DataflowNode:
    """A single operation node in the dataflow graph.

    Every node carries:
      id            — unique within its graph
      kind          — one of the kinds listed in the module docstring
      semantics     — dict of operation-specific fields (see extract_graph)
      type          — result type ("int", "float", "bool", "string", "unit", "?")
      symbolic_name — original variable name in source
      source_line, source_col — source location
      inputs, outputs — dataflow edges (node ids)
    """

    def __init__(self, node_id: int, kind: str, semantics: dict, instr=None):
        self.id = node_id
        self.kind = kind
        self.semantics = semantics
        self.instr = instr
        self.inputs: list[int] = []
        self.outputs: list[int] = []
        self.type: str = "?"
        self.symbolic_name: str = ""
        self.source_line: int = 0
        self.source_col: int = 0

    def __repr__(self):
        return f"DFNode({self.id}: {self.kind} {self.semantics})"


class DataflowGraph:
    """A dataflow graph for one function."""
    def __init__(self, func_name="main"):
        self.func_name = func_name
        self.nodes: dict[int, DataflowNode] = {}
        self._next_id = 0

    def new_node(self, kind: str, semantics: dict, instr=None) -> DataflowNode:
        nid = self._next_id
        self._next_id += 1
        node = DataflowNode(nid, kind, semantics, instr)
        self.nodes[nid] = node
        return node

    def add_edge(self, from_id: int, to_id: int):
        if from_id in self.nodes and to_id in self.nodes:
            self.nodes[from_id].outputs.append(to_id)
            self.nodes[to_id].inputs.append(from_id)

    def to_dot(self) -> str:
        """Export as DOT graph for visualization."""
        lines = [f"digraph {self.func_name} {{", "    rankdir=TB;"]
        for nid, node in self.nodes.items():
            label = f"{node.kind}"
            if node.symbolic_name:
                label += f"\\n{node.symbolic_name}"
            if node.type and node.type != "?":
                label += f" : {node.type}"
            safe = label.replace('"', '\\"')
            lines.append(f'    n{nid} [label="{safe}", shape=box];')
        for nid, node in self.nodes.items():
            for out in node.outputs:
                lines.append(f"    n{nid} -> n{out};")
        lines.append("}")
        return "\n".join(lines)

    def __repr__(self):
        return f"DataflowGraph({self.func_name}: {len(self.nodes)} nodes)"


# ----- Extraction helpers -----

def _type_str(typ) -> str:
    if typ is None:
        return "?"
    if isinstance(typ, str):
        return typ
    if hasattr(typ, 'name'):
        return typ.name
    return str(typ)


def _binop_semantics(op: str) -> dict:
    """Return semantics dict for a binary arithmetic/logic operation."""
    base = {"operation": op}
    if op in ("+", "-", "*", "/", "%"):
        base["category"] = "arithmetic"
        base["overflow"] = "undefined"  # current default; could be "wrapping"
    elif op in ("==", "!=", "<", ">", "<=", ">="):
        base["category"] = "comparison"
    elif op in ("&&", "||"):
        base["category"] = "logical"
    else:
        base["category"] = "unknown"
    return base


# ----- Extraction -----

def extract_graph(func: FunctionDef) -> DataflowGraph:
    """Build a DataflowGraph from a linear-IR FunctionDef.

    Each instruction becomes one node with a structured ``semantics`` dict.
    Edges follow def-use chains via IRVar identity.
    """
    g = DataflowGraph(func.name)
    var_node: dict[int, int] = {}
    instr_node: dict[int, int] = {}

    # ── Pass 1: create a node for every instruction ──
    for block in func.blocks:
        _ = g.new_node("block", {"name": block.name})
        for instr in block.instrs:
            sem: dict = {}
            kind = _instr_kind_and_sem(instr, sem)

            node = g.new_node(kind, dict(sem), instr)
            instr_node[id(instr)] = node.id
            if hasattr(instr, 'line'):
                node.source_line = instr.line
                node.source_col = instr.col

            # Dest variable carries result type
            if hasattr(instr, 'dest') and instr.dest is not None:
                node.type = _type_str(instr.dest.type)
                node.symbolic_name = instr.dest.name
                var_node[id(instr.dest)] = node.id

    # ── Pass 2: add edges for def-use chains ──
    def _use_var(var: IRVar, consumer_id: int):
        producer = var_node.get(id(var))
        if producer is not None:
            g.add_edge(producer, consumer_id)

    for block in func.blocks:
        for instr in block.instrs:
            nid = instr_node.get(id(instr))
            if nid is None:
                continue
            # Connect based on instruction type
            if isinstance(instr, BinaryInstr):
                _use_var(instr.left, nid)
                _use_var(instr.right, nid)
            elif isinstance(instr, UnaryInstr):
                _use_var(instr.operand, nid)
            elif isinstance(instr, CallInstr):
                for a in instr.args:
                    _use_var(a, nid)
            elif isinstance(instr, ReturnInstr):
                if instr.value:
                    _use_var(instr.value, nid)
            elif isinstance(instr, LoadInstr):
                _use_var(instr.addr, nid)
            elif isinstance(instr, StoreInstr):
                _use_var(instr.addr, nid)
                _use_var(instr.value, nid)
            elif isinstance(instr, LoadFieldInstr):
                _use_var(instr.struct, nid)
            elif isinstance(instr, StoreFieldInstr):
                _use_var(instr.struct, nid)
                _use_var(instr.value, nid)
            elif isinstance(instr, LoadIndexInstr):
                _use_var(instr.array, nid)
            elif isinstance(instr, StoreIndexInstr):
                _use_var(instr.array, nid)
                _use_var(instr.value, nid)
            elif isinstance(instr, LoadIndexVarInstr):
                _use_var(instr.array, nid)
                _use_var(instr.index_var, nid)
            elif isinstance(instr, StoreIndexVarInstr):
                _use_var(instr.array, nid)
                _use_var(instr.index_var, nid)
                _use_var(instr.value, nid)
            elif isinstance(instr, BranchInstr):
                _use_var(instr.cond, nid)
            elif isinstance(instr, RefInstr):
                _use_var(instr.variable, nid)
            elif isinstance(instr, MakeEnumInstr):
                for a in instr.args:
                    _use_var(a, nid)
            elif isinstance(instr, LoadEnumTagInstr):
                _use_var(instr.enum_var, nid)
    return g


def _instr_kind_and_sem(instr, sem: dict) -> str:
    """Classify an IR instruction and fill *sem* with structured fields."""
    if isinstance(instr, ConstInstr):
        sem["value"] = instr.value
        sem["type"] = instr.type
        return "const"
    if isinstance(instr, BinaryInstr):
        sem["operation"] = instr.op
        sem.update(_binop_semantics(instr.op))
        return "binary"
    if isinstance(instr, UnaryInstr):
        sem["operation"] = instr.op
        if instr.op == "-":
            sem["category"] = "arithmetic"
        elif instr.op == "!":
            sem["category"] = "logical"
        elif instr.op == "&":
            sem["category"] = "reference"
        elif instr.op == "*":
            sem["category"] = "dereference"
        else:
            sem["category"] = "unknown"
        return "unary"
    if isinstance(instr, CallInstr):
        sem["function"] = instr.func
        sem["arg_count"] = len(instr.args)
        return "call"
    if isinstance(instr, ReturnInstr):
        sem["has_value"] = instr.value is not None
        return "return"
    if isinstance(instr, AllocInstr):
        sem["alloc_type"] = _type_str(instr.type)
        return "alloc"
    if isinstance(instr, AllocStructInstr):
        sem["struct_name"] = instr.struct_name
        sem["field_count"] = instr.field_count
        return "alloc_struct"
    if isinstance(instr, AllocArrayInstr):
        sem["size"] = instr.size
        sem["element_size"] = 8  # hardcoded for now
        return "alloc_array"
    if isinstance(instr, LoadInstr):
        return "load"
    if isinstance(instr, StoreInstr):
        return "store"
    if isinstance(instr, LoadFieldInstr):
        sem["field"] = instr.field
        sem["field_index"] = instr.field_index
        return "load_field"
    if isinstance(instr, StoreFieldInstr):
        sem["field"] = instr.field
        sem["field_index"] = instr.field_index
        return "store_field"
    if isinstance(instr, LoadIndexInstr):
        sem["index"] = instr.index
        return "load_index"
    if isinstance(instr, StoreIndexInstr):
        sem["index"] = instr.index
        return "store_index"
    if isinstance(instr, LoadIndexVarInstr):
        return "load_index_var"
    if isinstance(instr, StoreIndexVarInstr):
        return "store_index_var"
    if isinstance(instr, LoadEnumTagInstr):
        return "load_enum_tag"
    if isinstance(instr, MakeEnumInstr):
        sem["variant"] = instr.variant
        sem["arg_count"] = len(instr.args)
        return "make_enum"
    if isinstance(instr, RefInstr):
        return "ref"
    if isinstance(instr, BranchInstr):
        sem["true_label"] = instr.true_label
        sem["false_label"] = instr.false_label
        return "branch"
    if isinstance(instr, JumpInstr):
        sem["target"] = instr.label
        return "jump"
    if isinstance(instr, LabelInstr):
        sem["label"] = instr.label
        return "label"
    if isinstance(instr, PhiInstr):
        sem["choices"] = [(str(s), str(v)) for s, v in instr.choices]
        return "phi"

    sem["ir_type"] = type(instr).__name__
    return "unknown"


def extract_all(module: Module) -> dict[str, DataflowGraph]:
    """Extract dataflow graphs for all functions in a module."""
    return {f.name: extract_graph(f) for f in module.functions}
