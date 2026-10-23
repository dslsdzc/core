# 第 1 波任务 4 报告：tag2l.cr 整搬（mw 族纯编码，整函数搬移）

状态：完成，单提交。提交 `d65fc1b8`，change `momomulk`。
提交信息：`refactor: x86 实例化波 1 Task 4——tag2l.cr 整搬（mw 族纯编码 + tag 表 owner 携行; frame↔tag2l 同轴双向引用裁定注记）`

工作区改动为 1 个新增文件和 10 个修改文件，见第 1 节；`jj status` 没有其他残留。

## 1. 搬迁边界和形式变化

### 1.1 新文件 `src/arch/x86_64/tag2l.cr`（547 行）

| 组成 | 来源（verbatim） |
|---|---|
| 文件头注 26 行：轴定位，即架构轴 tag 和 2L 编码族；tag 表 owner 说明；frame 与 tag2l 同轴双向引用裁定②；解析路径和段内顺序 | 新写，任务说明要求项 |
| mw 章节头，原 `instr.cr` 94-146：值表示、识别规则 A、B、B'、M1 边界、消费方接口、任务 5 的 D6 定案 | `instr.cr` 94-146，只有 1 处指针措辞，见第 1.3 节 |
| `mw_setup_tags`，tag 表 owner，写入侧 | `instr.cr` 148-224 |
| `mw_int_arith_jo_needed`，HIT 表路径排除门，加 `e2_mw_jo` | `instr.cr` 226-264 |
| `e2_mw_slow_block`，函数尾慢路径块，含 128 位推演注 | `instr.cr` 266-338 |
| `e2_mw_t8/b8/ld8/st8/tag_clr/tag_cpy`，tag 卫生字节助手；`mw_oc_new` 和 `e2_mw_oc_check`；`e2_mw_ld2` 和 `e2_mw_sext`；`e2_mw_opnd_block`，2L 操作数块 | `instr.cr` 340-613，章节头和全部函数 verbatim |

共整搬 15 个函数。全仓 grep `^fn e2_mw\|^fn mw_`，结果全部落在 `tag2l.cr`，零重复定义。

不动的函数，按任务说明清单核验：e2_w8、e2_w32、e2_w64、emit_rex、emit_modrm、emit_sib、e2_mov、e2_ld、e2_st、e2_li、e2_lr、e2_lrb、e2_lb、e2_call、e2_jmp、e2_je、e2_jae、e2_alu、e2_sd_load、e2_sd_store、e2_store_ret、e2_push_xmm0、e2_load_var 全部仍在 `instr.cr`，逐一 grep 验证过。`g2_tag_off` 和 `pf_frame_size`，原名 mw_frame_size，仍在 `frame.cr`，未动。

### 1.2 instr.cr（2588 行变为 2052 行）

mw 章节原位留 6 行指针注，指向 `tag2l.cr`，说明值表示、识别规则、边界、tag 卫生、块编码，以及本文件保留面；另加 1 个空行。净减少 513 行，即迁出 520 行加 7 行指针注，行数对账一致。`emit_instr` 和全部 `e2_*` 原语零改动。

### 1.3 形式变化（决策是只改调用点引用和注释指针，零代码行变化）

| 位置 | 变化 |
|---|---|
| 迁出段的 4 处指针 | ①“本文件 mw 族消费点”改为“instr.cr/frame.cr 的 mw 族消费点”，迁入 tag2l 后原措辞失真；②③“elf.cr 函数尾统一发射块并回填”和“elf.cr 于块位置已知后回填”改为 `frame.cr pf_epilogue`，任务 3 已把函数尾块发射移到 frame，移前就是陈旧指针，随迁顺手修正；④ tag 卫生③“参数保存（elf.cr）”改为 `frame.cr pf_prologue`，同上 |
| instr.cr 调用点 | IR_BINARY 的 add/sub 站点注从“e2_mw_slow_block，elf.cr 函数尾按站点发射”改为“tag2l.cr；块发射 = frame.cr pf_epilogue” |
| frame.cr 5 处 | `:21/:38` 的标签表读取注“表由 instr.cr mw_setup_tags”改为 tag2l.cr；`:28-31` 的 Depends on 拆为 instr.cr 和 tag2l.cr，并加反向边注；`:240/:262` 的 `pf_epilogue` 内两处 `e2_mw_slow_block` 和 `e2_mw_opnd_block` 从 instr.cr 改为 tag2l.cr |
| globals.cr 3 处 | jo 站点表头“elf.cr 于该函数尾声…发射块”改为 `frame.cr pf_epilogue`，这是任务 3 的遗留；“e2_mw_slow_block 注释”和“e2_mw_opnd_block（instr.cr）”标为 tag2l.cr |
| sizes.cr | 单源 NEVER-hardcode 清单加 tag2l.cr，沿用任务 2、3 加 entry.cr 和 frame.cr 的先例；新增 `sz_callee_saved_push/pop`，见第 1.4 节 |
| 测试 docstring 4 个文件 | test_mw_task1 两处、task2 一处、task3 一处、task4 一处，指向 tag2l.cr |

### 1.4 可选 hygiene（任务说明的“Minor 顺手”项，已做，低风险）

- `sizes.cr` 新增 `sz_callee_saved_push()` 和 `sz_callee_saved_pop()`，各 9B：push rbx 加 r12 到 r15，pop r15 到 r12 加 rbx。
- `frame.cr pf_frame_overhead`：`+ 18` 改为 `+ sz_callee_saved_push() + sz_callee_saved_pop()`，仍等于 18；`+ 9` 改为 `+ sz_callee_saved_pop()`，仍等于 9。数值逐字节保持，sizes.cr 的单源注成为事实。
- 顺带发现一个既有形态，未改，见第 4 节关注点 3。

## 2. 判据（全部 `nice -n 19`；先清 `.core/cache`；冻结源轮）

| 面 | 结果 |
|---|---|
| `build_selfhost_native.py` | BUILD SUCCESS；`[GUARD] corec/corearch/x86_64-linux target` manifest OK；三段 `build log clean (error[ = 0, undefined = 0)` |
| `test_backend_bootstrap.py` | 11/11 通过，stage1 等于 stage2 等于 stage3 byte-identical，O2 metadata 链，`error[` 门零命中 |
| mw1-6 全套 | task1 44 PASS，task2 48，task3 18，task4 60，task5 15，task6 24，全部通过，零失败 |
| `test_compile.py` | 全部 selfhost 编译测试通过 |
| `test_hit_table.py` | 24/24 通过。`mw_int_arith_jo_needed` 是表路径排除门，所在文件已迁，表路径零变化 |
| `test_live_ranges.py` | 13/13 通过 |
| 加测，第 1 波全局约束面 | ccr_v7 24/24、region_cfg 22/22、slice_bounds 7/7、ent_kernel 中立性通过（A+B clean）、bootstrap 三套 29/29、4/4、3/3 |
| full-bootstrap 守卫 | `corec build src/compiler/main.cr -o corec2 -O 0` rc=0，corec2 再构建 rc=0；`cmp corec2 corec3` rc=0；两日志 `error[` 为 0、`Undefined name:` 为 0、`Undefined function` 为 0；corec2、corec3 和 `.ccr` 已删净 |

### 2.1 跨树字节级证据（决定性，超越套件自洽）

用 `jj workspace add --revision @-` 建改动前的独立树 `/tmp/w1t4-base`，用 Python bootstrap 同管线重建旧 corearch。对同一份 `.ccr`，即全量 corearch 自举的 541 个函数，分别用旧 corearch 和新 corearch 发射：

| 产物 | 结果 |
|---|---|
| `build/corec`，跨树 md5 | 相同，`1212ed0234ec61a9be39a909685c9b8b`，前端不受影响 |
| `build/corearch`，跨树 md5 | 不同，`8d6bb6…` 对 `a44bce…`。声明序块位置移动是搬迁的必然结果，Python bootstrap 按声明序排函数，不是行为差异 |
| corearch 自举全量 @O0（2075886 B） | ELF byte-identical，`cmp` rc=0 |
| corearch 自举全量 @O2（regalloc 元数据路径） | ELF byte-identical，`cmp` rc=0 |
| project-mode 加载迹 | `-> src/arch/x86_64/tag2l.cr` 在第 20 行，紧随 instr.cr、先于 frame.cr；`import tag2l` 经回退链零解析变化 |

同一份 `.ccr` 配新旧 corearch，差异只可能来自本次搬迁。全量自举 ELF 逐字节相同，说明 mw 族编码、块发射和回填序零变化，tag 表 owner 移位和段内顺序变化，即 tag2l 插入，都没有行为后果。复现见第 5 节。

## 3. 零语义改动说明

- 搬迁是 R 型：520 行 verbatim 迁出。用 `diff` 比较旧 94-613 和新文件正文，只有第 1.3 节的 4 处注释指针差异，逐行核验过。
- 唯一的非注释代码改动是第 1.4 节的尺寸原语提取，`9+9=18`、`9=9`，数值恒等。
- 构建清单插入位置为 instr、tag2l、frame，只影响 concat 声明序，进而影响 bootstrap 的 `.s` 块位置，不影响全局序，因为 tag2l.cr 零全局声明。这一点由第 2.1 节的 ELF 逐字节相同实证。

## 4. 关注点和需要评审确认的地方

1. mw 章节头，原 `instr.cr` 94-146，30 行，随迁决定，超出任务说明的逐函数清单一步。该块自称“本文件 mw 族消费点”，且 `mw_setup_tags` 的内部注引用“本文件 e2_mw_opnd_block 前‘Task 4：tag 卫生’注释块”。不随迁的话，两处内部引用会同时失真，tag 表 owner 的规则文本也会和 owner 分居。因此整章随迁，`instr.cr` 留指针注，内容 verbatim，只改 1 处措辞指针。如果评审认为章节应留在 instr.cr，回搬这 30 行并改 2 处内部引用即可，无行为影响。
2. frame 和 tag2l 的双向引用，任务 3 评审裁定②，已实施注记：tag2l 到 frame 读 `g2_tag_off` 表，frame 到 tag2l 是 `pf_epilogue` 调用 `e2_mw_slow_block/e2_mw_opnd_block`。两个文件的头注、清单段注释和 `_import.cr` 三处都写明“同轴，两条构建路径容忍”，即 concat 扁平单元和组合根清单。实证是第 2 节全部通过，第 2.1 节加载迹无变化。
3. `pf_frame_overhead` 的 callee-saved 计入疑似既有超计，未改，第 1 波零变化约束。现式为 `+18`，即 push 9 加 pop 9，另加 `+9` 的 pop，共 27。而 `pf_prologue/pf_epilogue` 实际的 callee-saved 开销是 9 push 加 9 pop，共 18，每个 opt≥1 函数多估 9B。该值只进入 Phase 2 的 `total_code` 估算，用于缓冲和布局预案，不影响发射字节，第 2.1 节双 O 级逐字节相同可以证明。本次 hygiene 只把 18 和 9 提为 `sz_*` 原语并保持数值。是否清算该超计，建议第 2 波做 H2 面复核时决定；如果清算，需要单独判据，不与结构波混合。
4. 构建清单注释同步面：`build_selfhost_native.py` 的架构段注释写明段内顺序取舍依据，即 instr、tag2l、frame，“被依赖者先”，并说明双向边，避免后续波次误判顺序是随意的。

## 5. 复现（评审用）

```bash
cd /home/DslsDZC/core
rm -rf .core/cache
nice -n 19 python3 build_selfhost_native.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
for t in 1 2 3 4 5 6; do nice -n 19 python3 tests/selfhost/test_mw_task$t.py; done
nice -n 19 python3 tests/selfhost/test_hit_table.py
nice -n 19 python3 tests/selfhost/test_live_ranges.py
nice -n 19 python3 tests/selfhost/test_compile.py

# full-bootstrap guard
nice -n 19 build/corec build src/compiler/main.cr -o build/corec2 --static -O 0
nice -n 19 build/corec2 build src/compiler/main.cr -o build/corec3 --static -O 0
cmp build/corec2 build/corec3; rm -f build/corec2 build/corec3 build/corec2.ccr build/corec3.ccr

# 跨树字节对照（改动前树 = Task 3 提交 = d65fc1b8-）
jj workspace add --revision d65fc1b8- /tmp/w1t4-base && cd /tmp/w1t4-base && nice -n 19 python3 build_selfhost_native.py
mkdir -p /tmp/w1t4-cmp && cd /tmp/w1t4-base
build/corec build src/targets/x86_64-linux -o /tmp/w1t4-cmp/base_O0 --static -O 0
build/corec build src/targets/x86_64-linux -o /tmp/w1t4-cmp/base_O2 --static -O 2
build/corearch /tmp/w1t4-cmp/base_O0.ccr --static -o /tmp/w1t4-cmp/old_O0
build/corearch /tmp/w1t4-cmp/base_O2.ccr --static -o /tmp/w1t4-cmp/old_O2
cd /home/DslsDZC/core
build/corearch /tmp/w1t4-cmp/base_O0.ccr --static -o /tmp/w1t4-cmp/new_O0
build/corearch /tmp/w1t4-cmp/base_O2.ccr --static -o /tmp/w1t4-cmp/new_O2
cmp /tmp/w1t4-cmp/old_O0 /tmp/w1t4-cmp/new_O0   # 期望 rc=0
cmp /tmp/w1t4-cmp/old_O2 /tmp/w1t4-cmp/new_O2   # 期望 rc=0
```

证据留在仓库外：`/tmp/w1t4_*.log`、`/tmp/w1t4-cmp/`、`/tmp/w1t4-base`（jj workspace，评审后可以执行 `jj workspace forget`）。
