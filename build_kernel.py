#!/usr/bin/env python3
"""build_kernel.py —— 构建 McTT→Core 内核 CLI（build/kernel）

内核文件列表 = src/kernel/*.cr（term_io/mctt/subst/nbe/subtype/check/kernel_main）
+ 依赖（rt.cr 的 argv 全局、io.cr/fmt.cr 的输出与字符串操作）。
复用 build_selfhost_native.py 的 Python bootstrap 管线（compile_and_assemble）。
"""
import sys

sys.path.insert(0, '.')

import build_selfhost_native as b

b.build_runtime()  # build/runtime.o（幂等）

src = b.concat(
    [
            'src/runtime/rt.cr',
        'src/stdlib/io.cr',
        'src/stdlib/fmt.cr',
        'src/stdlib/toml.cr',
        'src/stdlib/os.cr',
        'src/stdlib/hotpatch.cr',    # rt.s 的 _hotpatch_sighup 引用 hp_load_config
        'src/stdlib/panic.cr',
        'src/stdlib/arena.cr',       # rt.s 引用 g_free
        'src/stdlib/goroutine.cr',   # rt.s 引用 sched_worker_run/goroutine_entry_wrapper
        'src/stdlib/chan.cr',        # rt.s 引用 chan_send
        'src/stdlib/sched.cr',       # rt.s 引用 sched_schedule
        'src/kernel/bytes.cr',       # 字节辅助（w64/r64/_dyncpy，自包含——信任根不依赖编译器全局）
        'src/kernel/term_io.cr',
        'src/kernel/mctt.cr',
        'src/kernel/subst.cr',
        'src/kernel/nbe.cr',
        'src/kernel/subtype.cr',
        'src/kernel/check.cr',
        'src/kernel/kernel_main.cr',
    ],
    wrapper_fn='kernel_main',
)

b.compile_and_assemble(src, label='kernel', out_name='kernel')
