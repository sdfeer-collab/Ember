#!/bin/zsh
# ============================================================
# Project Basilisk — 构建种子编译器 / build the seed compiler
# 仅用 as + ld（系统硬性底料），无 C 运行时、无 libc 启动代码。
#
# HeapForge 选择顺序：
#   1. HEAPFORGE_LIB=/path/libheapforge_asm.a ./build.sh   # 显式指定静态库
#   2. heapforge/src/*.s                                    # 完整版（默认）
#   3. vendor/heapforge_min/*.s                             # 最小子集兜底
# ============================================================
set -e
cd "$(dirname "$0")"
mkdir -p build

SDK="$(xcrun --show-sdk-path)"

as -arch arm64 -o build/seed.o src/seed.s

if [[ -n "$HEAPFORGE_LIB" ]]; then
    echo "[build] 使用外部 HeapForge 静态库: $HEAPFORGE_LIB"
    HF_OBJS="$HEAPFORGE_LIB"
elif [[ -d heapforge/src ]]; then
    echo "[build] 使用完整版 HeapForge (heapforge/src, 4100+ 断言库)"
    as -arch arm64 -o build/hf_platform.o    heapforge/src/platform.s
    as -arch arm64 -o build/hf_stack_alloc.o heapforge/src/stack_alloc.s
    as -arch arm64 -o build/hf_block_pool.o  heapforge/src/block_pool.s
    as -arch arm64 -o build/hf_free_list.o   heapforge/src/free_list.s
    HF_OBJS="build/hf_platform.o build/hf_stack_alloc.o build/hf_block_pool.o build/hf_free_list.o"
else
    echo "[build] 使用 vendor 最小 HeapForge (vendor/heapforge_min, 兜底)"
    as -arch arm64 -o build/hf_platform.o    vendor/heapforge_min/platform.s
    as -arch arm64 -o build/hf_block_pool.o  vendor/heapforge_min/block_pool.s
    as -arch arm64 -o build/hf_stack_alloc.o vendor/heapforge_min/stack_alloc.s
    HF_OBJS="build/hf_platform.o build/hf_block_pool.o build/hf_stack_alloc.o"
fi

# 供 test.sh 复用同一套对象文件链接测试产物
echo "$HF_OBJS" > build/hf_objs.txt

# -e _main：跳过 crt，入口直达种子编译器；-lSystem 仅为 dyld 硬性要求
ld -arch arm64 -syslibroot "$SDK" -e _main -o build/basilisk-seed \
   build/seed.o ${=HF_OBJS} -lSystem

echo "[build] OK -> build/basilisk-seed"
