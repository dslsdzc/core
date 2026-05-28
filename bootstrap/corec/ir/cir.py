"""
Core IR (.cir) — Dataflow graph IR.

The dataflow graph is the core semantic representation of a Core program.
Each node is an operation (constant, binary, call, etc.), and edges carry
data tokens from producer nodes to consumer nodes.

Lowering to .ccr (linear CFG IR) is a topological sort + scheduling pass.
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

    Each node has a unique id and corresponds to one IR instruction.
    """
    def __init__(self, node_id: int, label: str, instr=None):
        self.id = node_id
        self.label = label        # human-readable: "add", "const 42", etc.
        self.instr = instr        # source IR instruction (if any)
        self.inputs: list[int] = []    # node_ids of producers
        self.outputs: list[int] = []   # node_ids of consumers
        self.op = ""

    def __repr__(self):
        return f"DFNode({self.id}: {self.label})"


class DataflowGraph:
    """A dataflow graph for one function.

    Nodes are operations, edges are data token flow.
    """
    def __init__(self, func_name="main"):
        self.func_name = func_name
        self.nodes: dict[int, DataflowNode] = {}
        self._next_id = 0

    def new_node(self, label: str, instr=None) -> DataflowNode:
        nid = self._next_id
        self._next_id += 1
        node = DataflowNode(nid, label, instr)
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
            safe = node.label.replace('"', '\\"')
            lines.append(f'    n{nid} [label="{safe}", shape=box];')
        for nid, node in self.nodes.items():
            for out in node.outputs:
                lines.append(f"    n{nid} -> n{out};")
        lines.append("}")
        return "\n".join(lines)

    def __repr__(self):
        return f"DataflowGraph({self.func_name}: {len(self.nodes)} nodes)"


# ----- Extraction: reconstruct DataflowGraph from linear IR (.ccr) -----

def _instr_label(instr) -> str:
    """Short human label for an IR instruction."""
    if isinstance(instr, ConstInstr):
        return f"const {instr.value}"
    elif isinstance(instr, BinaryInstr):
        return instr.op
    elif isinstance(instr, UnaryInstr):
        return f"unary {instr.op}"
    elif isinstance(instr, CallInstr):
        return f"call {instr.func}"
    elif isinstance(instr, ReturnInstr):
        return "return"
    elif isinstance(instr, AllocInstr):
        return "alloc"
    elif isinstance(instr, AllocStructInstr):
        return "alloc_struct"
    elif isinstance(instr, AllocArrayInstr):
        return "alloc_array"
    elif isinstance(instr, LoadInstr):
        return "load"
    elif isinstance(instr, StoreInstr):
        return "store"
    elif isinstance(instr, LoadFieldInstr):
        return f"load_field {instr.field}"
    elif isinstance(instr, StoreFieldInstr):
        return f"store_field {instr.field}"
    elif isinstance(instr, LoadIndexInstr):
        return "load_index"
    elif isinstance(instr, StoreIndexInstr):
        return "store_index"
    elif isinstance(instr, LoadIndexVarInstr):
        return "load_index_var"
    elif isinstance(instr, StoreIndexVarInstr):
        return "store_index_var"
    elif isinstance(instr, LoadEnumTagInstr):
        return "load_enum_tag"
    elif isinstance(instr, MakeEnumInstr):
        return "make_enum"
    elif isinstance(instr, RefInstr):
        return "ref"
    elif isinstance(instr, BranchInstr):
        return f"branch {instr.true_label}/{instr.false_label}"
    elif isinstance(instr, JumpInstr):
        return f"jump {instr.label}"
    elif isinstance(instr, LabelInstr):
        return f"label {instr.label}"
    elif isinstance(instr, PhiInstr):
        return "phi"
    return type(instr).__name__


def extract_graph(func: FunctionDef) -> DataflowGraph:
    """Build a DataflowGraph from a linear-IR FunctionDef.

    Walks all basic blocks and instructions, tracking def-use chains
    via IRVar identity (Python id()).
    """
    g = DataflowGraph(func.name)
    var_node: dict[int, int] = {}  # id(var) -> node_id of producer
    instr_node: dict[int, int] = {}  # id(instr) -> node_id

    # Pass 1: create a node for every instruction
    for block in func.blocks:
        # Label node for the block itself
        label_node = g.new_node(block.name)
        for instr in block.instrs:
            node = g.new_node(_instr_label(instr), instr)
            instr_node[id(instr)] = node.id
            # If instr has a dest var, record who produces it
            if hasattr(instr, 'dest') and instr.dest is not None:
                var_node[id(instr.dest)] = node.id

    # Pass 2: add edges for def-use chains
    def _use_var(var: IRVar, consumer_id: int):
        """Connect consumer_id to var's producer if known."""
        producer = var_node.get(id(var))
        if producer is not None:
            g.add_edge(producer, consumer_id)

    def _use_instr(instr, consumer_id: int):
        """Connect consumer_id to instr's node."""
        nid = instr_node.get(id(instr))
        if nid is not None:
            g.add_edge(nid, consumer_id)

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


def extract_all(module: Module) -> dict[str, DataflowGraph]:
    """Extract dataflow graphs for all functions in a module."""
    return {f.name: extract_graph(f) for f in module.functions}
