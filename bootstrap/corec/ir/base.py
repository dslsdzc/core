from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from enum import Enum, auto

class IRNode:
    pass

class VarKind(Enum):
    LOCAL = auto()
    PARAM = auto()
    GLOBAL = auto()
    TEMP = auto()

@dataclass
class IRVar:
    name: str
    kind: VarKind
    type: Any = None
    id: int = 0