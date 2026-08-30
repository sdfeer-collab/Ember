// ============================================================
// HeapForge 最小子集 — 线性栈分配器 / stack allocator (vendor 占位)
// bump 分配 + LIFO 校验 + mark/rewind；控制块 64B 自托管于映射头部。
//
// 映射布局：[64B 控制块][数据区]
// 控制块：  [0]=数据区基址 [8]=capacity [16]=offset（已用）
//           [24]=映射总长  [32]=最近一次分配的用户指针（LIFO 校验）
// 分配单元：[16B 头 {prev_offset, prev_last_user}][用户数据，16 对齐]
// ============================================================

.text

// void* hf_asm_stack_create(uint64_t capacity)
.globl _hf_asm_stack_create
.p2align 2
_hf_asm_stack_create:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    cbz  x0, 8f
    add  x19, x0, #79               // capacity 上取 16 + 控制块 64
    and  x19, x19, #~15
    mov  x0, x19
    bl   _hf_asm_vm_reserve
    cbz  x0, 9f
    add  x9, x0, #64                // 数据区基址
    sub  x10, x19, #64              // 实际容量
    stp  x9, x10, [x0]
    str  xzr, [x0, #16]             // offset = 0
    str  x19, [x0, #24]
    str  xzr, [x0, #32]             // last_user = 0
    b    9f
8:  mov  x0, #0
9:  ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// void hf_asm_stack_destroy(void* ctx)
.globl _hf_asm_stack_destroy
.p2align 2
_hf_asm_stack_destroy:
    cbz  x0, 1f
    ldr  x1, [x0, #24]
    b    _hf_asm_vm_release
1:  ret

// void* hf_asm_stack_alloc(void* ctx, uint64_t size) — 用户指针 16 对齐
.globl _hf_asm_stack_alloc
.p2align 2
_hf_asm_stack_alloc:
    cbz  x0, 8f
    cbz  x1, 8f
    add  x1, x1, #15                // size 上取 16
    and  x1, x1, #~15
    add  x1, x1, #16                // + 16B 头
    ldp  x9, x10, [x0]              // 基址 / capacity
    ldr  x11, [x0, #16]             // offset
    add  x12, x11, x1
    cmp  x12, x10
    b.hi 8f                         // 容量不足
    add  x13, x9, x11               // 头地址
    ldr  x14, [x0, #32]
    stp  x11, x14, [x13]            // 头 = {prev_offset, prev_last_user}
    str  x12, [x0, #16]             // 提交新 offset
    add  x15, x13, #16              // 用户指针
    str  x15, [x0, #32]             // 更新 last_user（LIFO 链头）
    mov  x0, x15
    ret
8:  mov  x0, #0
    ret

// int64_t hf_asm_stack_free(void* ctx, void* ptr) — -1 = 非 LIFO
.globl _hf_asm_stack_free
.p2align 2
_hf_asm_stack_free:
    cbz  x0, 8f
    ldr  x9, [x0, #32]              // last_user
    cmp  x1, x9
    b.ne 8f                         // 只允许释放最近一次分配
    cbz  x1, 8f
    sub  x10, x1, #16               // 头地址
    ldp  x11, x12, [x10]            // {prev_offset, prev_last_user}
    str  x11, [x0, #16]
    str  x12, [x0, #32]
    mov  x0, #0
    ret
8:  mov  x0, #-1
    ret

// uint64_t hf_asm_stack_mark(void* ctx)
.globl _hf_asm_stack_mark
.p2align 2
_hf_asm_stack_mark:
    ldr  x0, [x0, #16]
    ret

// void hf_asm_stack_rewind(void* ctx, uint64_t marker)
.globl _hf_asm_stack_rewind
.p2align 2
_hf_asm_stack_rewind:
    ldr  x9, [x0, #16]
    cmp  x1, x9
    b.hi 1f                         // marker 不得超过当前 offset
    str  x1, [x0, #16]
    str  xzr, [x0, #32]             // 回卷后 LIFO 链失效，清 last_user
1:  ret

// uint64_t hf_asm_stack_used(void* ctx)
.globl _hf_asm_stack_used
.p2align 2
_hf_asm_stack_used:
    ldr  x0, [x0, #16]
    ret
