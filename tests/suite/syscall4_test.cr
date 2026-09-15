// syscall4_test.cr — syscall4 第四参 r10 径持久覆盖（波 1 Task 7 carry 项 a）
//
// 消费面：src/stdlib/os.cr `system(cmd)` —— fork + execve("/bin/sh","-c",cmd)
//         + wait4 收割退出码。
// 为什么是 syscall4：wait4 有 4 个非编号参数（pid, &status, options, rusage），
//   syscall3 只有 3 个通道，第 4 参落 rcx 被 `syscall` 指令破坏 → r10 残留垃圾
//   → 内核 EFAULT → 退出码传播不可靠。syscall4（src/os/linux/syscall.cr
//   sys_syscall4_stub）把第 4 参经 r10 传递——本程序为该径的**持久套件覆盖**
//   （波 1 Task 6 的覆盖仅是 /tmp 探针，未入树）。
//
// 判据形式（suite 惯例 = run_suite「main 返回 0 为通过」，见 src/ci/run.sh）：
//   子进程退出码经 wait 状态位 8..15 正确回传 → 本程序 rc=0；否则回传 rc=1/2
//   （等价 exit 断言：断言对象即 `system("exit 3") == 3` 本身）。
import io
import os

fn main() -> int {
    rc := system("exit 3");
    if rc != 3 {
        print("FAIL: system(\"exit 3\") rc=");
        println_i(rc);
        return 1;
    }
    // 第二探针换一个值：区分「常量/陈旧缓冲区回传」与真实状态位解码。
    rc2 := system("exit 42");
    if rc2 != 42 {
        print("FAIL: system(\"exit 42\") rc=");
        println_i(rc2);
        return 2;
    }
    println("ALL PASS");
    return 0;
}
