#!/usr/bin/env bash
# 判据载体化批（criteria-carrier）T1：**ELF canary + `.ccr` 四条 = 机器闸门**
#
# 缘起：canary sha 与 `.ccr` 四条锁定值在全国仓 `*.py/*.sh/*.cr/*.toml/*.yml` 里
# **命中数为 0**——只活在 docs/ 与 .superpowers/ 的文字里，每个批次的提交信息都在引用
# 它们，但那是**人工/代理手跑**的结果，不是机器闸门。同类事故本仓已发生过一次
# （`test_backend_bootstrap.py` 自称已挂 CI 而 run.sh 零命中 ⇒ `error[N06]` 跨 5 任务
# 33 次静默漏检，见 src/ci/run.sh:72-73 与 tests/harness/test_ci_hook_coverage.py）。
#
# 用法:
#   bash tools/baseline/canary_check.sh [<corec二进制>]
#       采集（5 条编译，逐条 clean-cache）+ 逐条校验。
#       rc=0 全绿 · rc=1 任一不符/缺件 · rc=2 用法错
#   bash tools/baseline/canary_check.sh --verify-only [<采集目录>]
#       只校验既有产物（不编译）——供 tests/harness/test_canary_carrier.py 的
#       「篡改产物 ⇒ 必红」牙用
#   bash tools/baseline/canary_check.sh --selftest
#       合成夹具自证（S1–S6；无编译器、毫秒级）：证明**闸门本身能变红**
# 环境:
#   CANARY_VALUES=<tsv>   值表路径（默认 tools/baseline/canary_values.tsv）——仅自证/牙用；
#                         生效时会打印显式告警行（不得在 CI 静默改指向）
#   CANARY_NO_NICE=1      免 nice（默认 nice -n 19，遵 CLAUDE.md 铁律 6）
#
# 配方（口径 = **冷态**；出处逐条实读）:
#   ELF canary : clean-cache → build tests/suite/ptr_arith.cr --static -o <D>/pa
#                （/tmp/capt1/t1b_criteria.sh:34-38；值 = 95084e7b…d475 · **28822B = ELF 文件大小**，
#                  `stat -c %s` 于 `\177ELF` 魔数的可执行产物上，本实例实核）
#   .ccr 四条  : 每条 clean-cache 前置 ——「ccr F -o O」与「build F -o O --static」（取 O.ccr）
#                （/tmp/capt1/t1b_criteria.sh:41-53 + .superpowers/sdd/cap-task1-report.md:82）
#                语料 A = tests/suite/ptr_arith.cr · 语料 B = tests/suite/generics_test.cr
#                两口径差恒 **143B**，根因 = `--static` 前置 rt.cr（main.cr:433-437）⇒ 4 全局 + 1 串入段。
#   环境       : **HOME 归一化**到采集目录内的空 home/（+ `CORE_SAFE=1`）——见下方「环境归一化」
#                注。**不做归一化**时 gt 两条会随开发机 `~/.core/lib/io/index` 漂 ±28B
#                （CI PR #80 红档的成因）。
#   **判据契约是两级的**（勿写成「永远不该变」，也勿写成「随便变」）：
#     canary ELF = 发射面零泄漏检测器（变 = 越界 ⇒ 停下上报）；
#     .ccr 四条  = 格式+内容形状检测器（**值变 ≠ 必然回归**，但**必须显式归因 + 同批重锁 + 旧值留痕**；
#                  无归因的变化 = 红）。**本闸门禁止的不是变化，是无声变化。**
#   **只锁冷态**（不得「补全」成冷暖双锁）——三条理由（记录值即冷态 / 非可选程序冷≠热是
#     P4 已豁免的预存面 / 暖态在本两档零区分力且另有专属闸门）。
#   以上两条的完整论证 + 两套历史值的关系（旧 v8 四值 `fb4a3b59…` 等 = 同口径不同时代，
#   非漂移）逐条见 tools/baseline/canary_values.tsv 头注与
#   docs/superpowers/plans/2026-09-16-criteria-carrier.md §1/§6。
#
# fail-closed 四条（逐条对应一个已知静默形态）:
#   F1 任一步 rc≠0 ⇒ 红（含编译失败/产物缺失）——防「编译挂了但没产物 ⇒ 跳过断言 ⇒ 绿」
#   F2 值表缺 name / 多 name / 条数≠5 ⇒ 红 ——防「值表被改小 ⇒ 断言面缩水而全绿」
#   F3 逐条比 sha256 **与** 字节数两项，任一不符 ⇒ 红 + 打印期望 vs 实际
#      ——防「只比尺寸 ⇒ 换内容同尺寸假绿」（尺寸单独报 = 更早诊断）
#   F4 工具/编译器缺失 ⇒ 红 ——防「环境缺件 ⇒ 空跑绿」
#
# 零足迹：本脚本**不自建**编译器（前置 = build/corec 存在，且 build 路径按
#   src/compiler/main.cr:713-721 用 get_arg(0) 目录拼 corearch ⇒ 要求 corearch 同目录）；
#   只写采集目录（默认 build/canary_artifacts/，build/ 不入库）+ 逐条 clean-cache
#   （相对 cwd 的 .core/cache/cir/，src/compiler/main.cr:408-414）⇒ 不写源树、不写判据面。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="${COREC_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
cd "$REPO_ROOT" || exit 2

D_CUR=""   # 采集目录（clean_cache/step_compile 的日志落点；只在采集路径赋值）

# ── 环境归一化（本闸门**必须**与开发机家目录解耦）──────────────────────────────
# 机理（2026-09-16 CI 红档实锤，PR #80）：编译器解析 `import` 时会读
# `$HOME/.core/lib/<模块名>/index`（扩展 .so 元数据索引，module.cr:523-530 实读），
# 命中则 `reg_so_funcs` 把其中声明的函数名驻留进 `.ccr` 串表 ⇒ **同一提交、同一编译器，
# 换台机器产物就变**（本机 `~/.core/lib/io/index` 160B ⇒ `generics_test` +2 串
# `print_int`/`println_int` = +28B）。
#   · 归一化 = `HOME` 钉到**采集目录内的空 home/**，且在输出里打印实际 HOME（可审计）；
#   · **不得 unset/置空 HOME**——`module.cr:526` 有一条硬编码兜底
#     `if str_len(home_dir) == 0 { home_dir = "/home/DslsDZC"; }`，置空反而会去读
#     **原开发者**的家目录（该缺陷已独立登记，见 TODO）。
#   · `CORE_SAFE` 同法钉成文档默认值 `1`（`ext_mgr.cr:41`：仅在显式 `=0` 时关安全面）
#     —— 防环境里一个 `CORE_SAFE=0` 造成假红。
CANARY_HOME=""
ENV_PIN=(env "CORE_SAFE=1")   # HOME 在采集时追加（见 collect_into）

VALUES_DEFAULT="$SCRIPT_DIR/canary_values.tsv"
DEFAULT_DIR="$REPO_ROOT/build/canary_artifacts"

# spec（**有序**；与值表按 name 对齐，两侧集合必须相等）
SPEC_NAMES=(canary_elf pa_ccr pa_static_ccr gt_ccr gt_static_ccr)
SPEC_TOTAL=5

artifact_of() {
  case "$1" in
    canary_elf)     printf '%s' "pa" ;;
    pa_ccr)         printf '%s' "pa.ccr" ;;
    pa_static_ccr)  printf '%s' "pa_st.bin.ccr" ;;
    gt_ccr)         printf '%s' "gt.ccr" ;;
    gt_static_ccr)  printf '%s' "gt_st.bin.ccr" ;;
    *) return 1 ;;
  esac
}

is_spec_name() {
  local n
  for n in "${SPEC_NAMES[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

usage() {
  sed -n '2,30p' "$SELF" | sed 's/^# \{0,1\}//'
  exit 2
}

# ────────────────────────── 校验（采集与自证共用同一函数） ──────────────────────────
# verify_dir <值表> <采集目录> ⇒ rc=0 全绿 / rc=1 任一不符
verify_dir() {
  local vf="$1" d="$2"
  local fails=0 checked=0 lineno=0 n art sh sz extra line
  local -A ESH=() ESZ=() EART=()

  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[FAIL] F4 缺工具：sha256sum（fail-closed：不能空跑绿）"
    return 1
  fi
  if [ ! -f "$vf" ]; then
    echo "[FAIL] F4 值表不存在：$vf"
    return 1
  fi

  # 解析值表（4 列 TSV；# 与空行忽略；格式非法 ⇒ 红）
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    IFS=$'\t' read -r n art sh sz extra <<< "$line"
    if [ -z "${n:-}" ] || [ -z "${art:-}" ] || [ -z "${sh:-}" ] || [ -z "${sz:-}" ] || [ -n "${extra:-}" ]; then
      echo "[FAIL] 值表第 $lineno 行格式非法（须 4 列 TSV：name/artifact/sha256/size）：$line"
      fails=$((fails + 1)); continue
    fi
    case "$sh" in *[!0-9a-f]*) echo "[FAIL] 值表 $n: sha256 非小写 hex：$sh"; fails=$((fails + 1)); continue ;; esac
    if [ "${#sh}" -ne 64 ]; then
      echo "[FAIL] 值表 $n: sha256 长度 ${#sh} ≠ 64"; fails=$((fails + 1)); continue
    fi
    case "$sz" in *[!0-9]*) echo "[FAIL] 值表 $n: size 非十进制：$sz"; fails=$((fails + 1)); continue ;; esac
    if [ -n "${ESH[$n]:-}" ]; then
      echo "[FAIL] 值表重复条目：$n"; fails=$((fails + 1)); continue
    fi
    ESH[$n]="$sh"; ESZ[$n]="$sz"; EART[$n]="$art"
  done < "$vf"

  # F2：spec ↔ 值表 **双向**集合相等（缺 = 断言面缩水；多 = 陈旧条目）
  for n in "${SPEC_NAMES[@]}"; do
    if [ -z "${ESH[$n]:-}" ]; then
      echo "[FAIL] F2 值表缺 spec 条目：$n（断言面缩水 ⇒ fail-closed）"
      fails=$((fails + 1))
    fi
  done
  for n in "${!ESH[@]}"; do
    if ! is_spec_name "$n"; then
      echo "[FAIL] F2 值表含 spec 之外的条目：$n"
      fails=$((fails + 1))
    fi
  done

  # F1/F3：逐条比 sha256 与字节数
  for n in "${SPEC_NAMES[@]}"; do
    [ -n "${ESH[$n]:-}" ] || continue
    art="${EART[$n]}"
    local p="$d/$art"
    if [ ! -e "$p" ]; then
      echo "[FAIL] F1 $n: 产物缺失 $p（期望 sha256=${ESH[$n]} size=${ESZ[$n]}）"
      fails=$((fails + 1)); continue
    fi
    local ash asz
    ash="$(sha256sum -- "$p" | cut -d' ' -f1)"
    asz="$(wc -c < "$p" | tr -d ' ')"
    checked=$((checked + 1))
    if [ "$asz" != "${ESZ[$n]}" ]; then
      echo "[FAIL] F3 $n: size 期望(expected)=${ESZ[$n]} 实际(actual)=$asz · $p"
      fails=$((fails + 1))
    fi
    if [ "$ash" != "${ESH[$n]}" ]; then
      echo "[FAIL] F3 $n: sha256 期望(expected)=${ESH[$n]} 实际(actual)=$ash · $p"
      fails=$((fails + 1))
    fi
    if [ "$ash" = "${ESH[$n]}" ] && [ "$asz" = "${ESZ[$n]}" ]; then
      echo "[PASS] $n: $ash ($asz B)"
    fi
  done

  if [ "$fails" -eq 0 ]; then
    echo "[canary] PASS $checked/$SPEC_TOTAL（值表 $vf · 目录 $d）"
    return 0
  fi
  echo "[canary] FAIL ${fails} 项（值表 $vf · 目录 $d）"
  return 1
}

# ────────────────────────── 采集（唯一需要编译器的一段） ──────────────────────────
COREC_BIN="./build/corec"
CMD=()
clean_cache() {
  local rc
  "${ENV_PIN[@]}" "HOME=$CANARY_HOME" "${CMD[@]}" clean-cache >| "$D_CUR/clean_cache.log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] F1 clean-cache rc=$rc（log=$D_CUR/clean_cache.log）"
    return 1
  fi
  return 0
}

# 一条编译：step_compile <名字> <日志名> <命令...>
step_compile() {
  local name="$1" log="$2"; shift 2
  local rc
  clean_cache || return 1
  "${ENV_PIN[@]}" "HOME=$CANARY_HOME" "${CMD[@]}" "$@" >| "$D_CUR/$log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] F1 采集 $name: rc=$rc（log=$D_CUR/$log）"
    sed -n '1,8p' "$D_CUR/$log" | sed 's/^/       | /'
    return 1
  fi
  return 0
}

collect_into() {
  local d="$1"
  D_CUR="$d"
  rm -rf "$d"; mkdir -p "$d"
  # 受控 HOME（采集目录内的空目录）——**非 unset**（防 module.cr:526 硬编码兜底）；
  # 打印实际值以便审计（本行即「闸门与开发机 $HOME 内容解耦」的证据面）。
  CANARY_HOME="$d/home"
  mkdir -p "$CANARY_HOME"
  echo "[canary] 环境归一化：HOME=$CANARY_HOME（空目录，已建）· CORE_SAFE=1 · corec=$COREC_BIN"
  step_compile canary_elf     pa.log     build tests/suite/ptr_arith.cr   --static -o "$d/pa"     || return 1
  step_compile pa_ccr         pa_ccr.log ccr   tests/suite/ptr_arith.cr   -o "$d/pa.ccr"         || return 1
  step_compile pa_static_ccr  pa_st.log  build tests/suite/ptr_arith.cr   --static -o "$d/pa_st.bin" || return 1
  step_compile gt_ccr         gt_ccr.log ccr   tests/suite/generics_test.cr -o "$d/gt.ccr"       || return 1
  step_compile gt_static_ccr  gt_st.log  build tests/suite/generics_test.cr --static -o "$d/gt_st.bin" || return 1
  return 0
}

# ────────────────────────── 自证：合成夹具 S1–S6 ──────────────────────────
selftest() {
  local tmp; tmp="$(mktemp -d)" || exit 1
  local fails=0 total=0 n
  local FX="$tmp/fx" TB="$tmp/values.tsv" OUT="$tmp/out.txt"

  mk_fixtures() {   # 确定性夹具（与判据值无关；值表由夹具派生）
    rm -rf "$tmp/fx"; mkdir -p "$tmp/fx"
    for n in "${SPEC_NAMES[@]}"; do
      printf 'canary-selftest-%s\n' "$n" >| "$tmp/fx/$(artifact_of "$n")"
    done
  }
  mk_table() {      # $1=输出文件；$2=要替换成的假 sha（空 = 用真值）；$3=丢弃的条目名（空 = 不丢）
    : >| "$1"
    for n in "${SPEC_NAMES[@]}"; do
      [ "${3:-}" = "$n" ] && continue
      local p="$tmp/fx/$(artifact_of "$n")" sh sz
      sh="$(sha256sum -- "$p" | cut -d' ' -f1)"; sz="$(wc -c < "$p" | tr -d ' ')"
      [ -n "${2:-}" ] && [ "$n" = "pa_ccr" ] && sh="$2"
      printf '%s\t%s\t%s\t%s\n' "$n" "$(artifact_of "$n")" "$sh" "$sz" >> "$1"
    done
  }
  st() {   # st <标签> <期望 rc> <值表> <目录> [需要的输出正则]
    local label="$1" want="$2" vf="$3" dir="$4" pat="${5:-}"
    total=$((total + 1))
    CANARY_VALUES="$vf" bash "$SELF" --verify-only "$dir" >| "$OUT" 2>&1
    local rc=$?
    if [ "$rc" -ne "$want" ]; then
      echo "[FAIL] selftest $label: rc=$rc 期望 $want"; sed -n '1,6p' "$OUT" | sed 's/^/       | /'
      fails=$((fails + 1)); return 1
    fi
    if [ -n "$pat" ] && ! grep -q "$pat" "$OUT"; then
      echo "[FAIL] selftest $label: rc=$rc 对，但输出缺「$pat」（红必须可诊断）"
      sed -n '1,6p' "$OUT" | sed 's/^/       | /'
      fails=$((fails + 1)); return 1
    fi
    echo "[PASS] selftest $label: rc=$rc${pat:+ · 命中 $pat}"
    return 0
  }

  # S1 自洽夹具 ⇒ 必须**绿**（证明绿路可达，不是恒红）
  mk_fixtures; mk_table "$TB"
  st "S1 自洽夹具⇒绿" 0 "$TB" "$FX"

  # S2 同尺寸翻转一字节 ⇒ 必须红，且打印 sha 的期望 vs 实际
  mk_fixtures; mk_table "$TB"
  printf 'X' | dd of="$FX/pa.ccr" bs=1 seek=0 conv=notrunc status=none
  st "S2 同尺寸改内容⇒红" 1 "$TB" "$FX" "sha256 期望(expected)=.*实际(actual)="

  # S3 截断（尺寸变） ⇒ 必须红，且打印 size 的期望 vs 实际
  mk_fixtures; mk_table "$TB"
  truncate -s -1 "$FX/gt.ccr"
  st "S3 尺寸变⇒红" 1 "$TB" "$FX" "size 期望(expected)=.*实际(actual)="

  # S4 缺产物 ⇒ 必须红（F1）
  mk_fixtures; mk_table "$TB"; rm -f "$FX/pa_st.bin.ccr"
  st "S4 缺产物⇒红" 1 "$TB" "$FX" "F1 pa_static_ccr: 产物缺失"

  # S5 值表少一条 ⇒ 必须红（F2：断言面缩水）
  mk_fixtures; mk_table "$TB" "" "gt_static_ccr"
  st "S5 值表少条目⇒红" 1 "$TB" "$FX" "F2 值表缺 spec 条目"

  # S6 值表期望 sha 换成假值 ⇒ 必须红
  mk_fixtures; mk_table "$TB" "0000000000000000000000000000000000000000000000000000000000000000"
  st "S6 假期望值⇒红" 1 "$TB" "$FX" "F3 pa_ccr: sha256 期望(expected)="

  rm -rf "$tmp"
  if [ "$fails" -eq 0 ]; then
    echo "[selftest] PASS $total/$total 子检按设计（绿路可达 + 5 类必红：改内容/改尺寸/缺产物/值表缩水/假期望）"
    return 0
  fi
  echo "[selftest] FAIL $(($total - $fails))/$total"
  return 1
}

# ────────────────────────── 入口 ──────────────────────────
MODE=collect
VERIFY_DIR=""
VALUES="${CANARY_VALUES:-$VALUES_DEFAULT}"

while [ $# -gt 0 ]; do
  case "$1" in
    --verify-only)
      MODE=verify
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then VERIFY_DIR="$2"; shift; fi
      ;;
    --selftest) MODE=selftest ;;
    --values)   shift; VALUES="${1:-}" ;;
    --help|-h)  usage ;;
    -*)         echo "error: 未知选项 $1" >&2; usage ;;
    *)          COREC_BIN="$1" ;;
  esac
  shift
done

if [ "$VALUES" != "$VALUES_DEFAULT" ]; then
  echo "[canary] ⚠ 值表被 CANARY_VALUES/--values 覆盖：$VALUES（默认 = $VALUES_DEFAULT）"
fi

case "$MODE" in
  selftest)
    selftest
    exit $?
    ;;
  verify)
    [ -n "$VERIFY_DIR" ] || VERIFY_DIR="$DEFAULT_DIR"
    # 只校验时也要求 corearch 存在吗？——不：--verify-only 不编译，与编译器无关。
    verify_dir "$VALUES" "$VERIFY_DIR"
    exit $?
    ;;
  collect)
    if [ ! -f "$COREC_BIN" ]; then
      echo "[FAIL] F4 编译器二进制不存在：$COREC_BIN"
      echo "       前置：nice -n 19 python3 build_selfhost_native.py（本脚本**不自建**）"
      exit 1
    fi
    if [ ! -x "$COREC_BIN" ]; then
      echo "[FAIL] F4 编译器不可执行：$COREC_BIN（rc=126 会被 F1 抓到，此处给更早的诊断）"
      exit 1
    fi
    if [ ! -f "$(dirname "$COREC_BIN")/corearch" ]; then
      echo "[FAIL] F4 同目录缺 corearch：$(dirname "$COREC_BIN")/corearch"
      echo "       （build 路径按 src/compiler/main.cr:713-721 用 get_arg(0) 目录拼 corearch）"
      exit 1
    fi
    if [ "${CANARY_NO_NICE:-0}" = "1" ]; then CMD=("$COREC_BIN"); else CMD=(nice -n 19 "$COREC_BIN"); fi
    echo "[canary] 采集目录 = $DEFAULT_DIR（corec = $COREC_BIN）"
    if ! collect_into "$DEFAULT_DIR"; then
      echo "[canary] FAIL 采集阶段（未进入校验）"
      exit 1
    fi
    verify_dir "$VALUES" "$DEFAULT_DIR"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "[canary] 判据不符 ⇒ **停下上报**（是回归就修回归，是越界就取裁；**勿改值表**——"
      echo "         换代纪律见 docs/superpowers/plans/2026-09-16-criteria-carrier.md §6）"
    fi
    exit $rc
    ;;
esac
exit 2
