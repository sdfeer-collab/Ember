// ============================================================
// HeapForge 最小子集 — 位图块池 / block pool (vendor 占位)
// RBIT+CLZ 两条指令定位最低空闲位；控制块 64B 自托管于映射头部。
//
// 映射布局：[64B 控制块][位图 words*8B，补齐 16B][块数据区]
// 控制块：  [0]=block_size [8]=block_count [16]=映射总长
//           [24]=used 计数 [32]=位图基址   [40]=数据区基址
// 位图：    bit=1 已占用；末字越界位在 create 时预置 1
// ============================================================

.text

// void* hf_asm_pool_create(uint64_t block_size, uint64_t block_count)
.globl _hf_asm_pool_create
.p2align 2
_hf_asm_pool_create:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    cbz  x0, 8f                     // 参数校验
    cbz  x1, 8f
    add  x19, x0, #15               // block_size 上取 16 的倍数（对齐契约）
    and  x19, x19, #~15
    mov  x20, x1

    add  x9, x20, #63               // 位图字数 = ceil(count/64)
    lsr  x9, x9, #6
    lsl  x21, x9, #3                // 位图字节数
    add  x21, x21, #15              // 补齐 16B，保证数据区 16 对齐
    and  x21, x21, #~15

    mul  x9, x19, x20               // 映射总长 = 64 + 位图 + 块区
    add  x9, x9, x21
    add  x22, x9, #64

    mov  x0, x22
    bl   _hf_asm_vm_reserve
    cbz  x0, 9f

    stp  x19, x20, [x0]             // 填控制块
    str  x22, [x0, #16]
    str  xzr, [x0, #24]
    add  x9, x0, #64                // 位图基址
    str  x9, [x0, #32]
    add  x10, x9, x21               // 数据区基址
    str  x10, [x0, #40]

    and  x11, x20, #63              // 末字越界位预置 1（mmap 页已零初始化）
    cbz  x11, 9f
    add  x12, x20, #63
    lsr  x12, x12, #6
    sub  x12, x12, #1               // 末字下标
    mov  x13, #-1
    lsl  x13, x13, x11              // 高位越界掩码
    str  x13, [x9, x12, lsl #3]
    b    9f
8:  mov  x0, #0
9:  ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// void hf_asm_pool_destroy(void* ctx)
.globl _hf_asm_pool_destroy
.p2align 2
_hf_asm_pool_destroy:
    cbz  x0, 1f
    ldr  x1, [x0, #16]              // 映射总长，一次 munmap 全回收
    b    _hf_asm_vm_release
1:  ret

// void* hf_asm_pool_alloc(void* ctx)   — 0 = 满
.globl _hf_asm_pool_alloc
.p2align 2
_hf_asm_pool_alloc:
    cbz  x0, 8f
    ldr  x9, [x0, #32]              // 位图基址
    ldr  x10, [x0, #8]              // block_count
    add  x11, x10, #63
    lsr  x11, x11, #6               // 位图字数
    mov  x12, #0                    // 字下标
1:  cmp  x12, x11
    b.hs 8f                         // 全满
    ldr  x13, [x9, x12, lsl #3]
    mvn  x14, x13
    cbz  x14, 2f                    // 整字全满，跳过 64 块
    rbit x15, x14                   // CTZ(~bits) = CLZ(RBIT(~bits))
    clz  x15, x15                   // 最低空闲位下标
    mov  x14, #1
    lsl  x14, x14, x15
    orr  x13, x13, x14              // 置位
    str  x13, [x9, x12, lsl #3]
    ldr  x14, [x0, #24]             // used++
    add  x14, x14, #1
    str  x14, [x0, #24]
    lsl  x14, x12, #6               // 块号 = 字下标*64 + 位下标
    add  x14, x14, x15
    ldr  x15, [x0]                  // block_size
    ldr  x9, [x0, #40]              // 数据区基址
    mul  x14, x14, x15
    add  x0, x9, x14
    ret
2:  add  x12, x12, #1
    b    1b
8:  mov  x0, #0
    ret

// int64_t hf_asm_pool_free(void* ctx, void* ptr) — -1 = 错位/越界/double-free
.globl _hf_asm_pool_free
.p2align 2
_hf_asm_pool_free:
    cbz  x0, 8f
    cbz  x1, 8f
    ldr  x9, [x0, #40]              // 数据区基址
    subs x10, x1, x9
    b.lo 8f                         // 低于数据区
    ldr  x11, [x0]                  // block_size
    udiv x12, x10, x11
    msub x13, x12, x11, x10
    cbnz x13, 8f                    // 未对齐块边界 = 错位指针
    ldr  x13, [x0, #8]
    cmp  x12, x13
    b.hs 8f                         // 越界
    ldr  x9, [x0, #32]              // 位图基址
    lsr  x13, x12, #6               // 字下标
    and  x14, x12, #63              // 位下标
    ldr  x15, [x9, x13, lsl #3]
    mov  x10, #1
    lsl  x10, x10, x14
    tst  x15, x10
    b.eq 8f                         // 位已清 = double-free
    bic  x15, x15, x10
    str  x15, [x9, x13, lsl #3]
    ldr  x14, [x0, #24]             // used--
    sub  x14, x14, #1
    str  x14, [x0, #24]
    mov  x0, #0
    ret
8:  mov  x0, #-1
    ret

// uint64_t hf_asm_pool_used(void* ctx)
.globl _hf_asm_pool_used
.p2align 2
_hf_asm_pool_used:
    ldr  x0, [x0, #24]
    ret
