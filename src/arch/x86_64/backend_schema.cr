// === backend_schema.cr ===
// Optimization metadata keys written by the x86-64 backend into the .ccr OPT
// section. The frontend does not read these keys.

OPT_KEY_REG_ASSIGN : int = 0   // [var_idx:u32, reg_num:u8]
OPT_KEY_STACK_SHARE : int = 1  // [var_idx:u32, mapped_to:u32]
OPT_KEY_CSE : int = 2          // [op:u32, s1:u32, s2:u32, res:u32]
