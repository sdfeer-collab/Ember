// HeapForge (ASM) - 线性栈分配器 / Stack (bump-pointer) allocator.
// 上下文自带在映射头部（64B），帧头 16B 记录 prev_top/prev_payload，
// 支持 LIFO 释放与 mark/rewind 整段回滚。全部分配 16 字节对齐。
// Context lives in the mapping header (64B); 16B frame header records
// prev_top/prev_payload for LIFO frees and mark/rewind. 16-byte aligned.
//
// 上下文布局 / context layout (offsets):
//   0: base (数据区绝对地址 / data area address)
//   8: capacity
//  16: top          (相对数据区 / relative to data area)
//  24: last_payload (usize::MAX = 无 / none)
//  32: alloc_calls
//  40: free_calls

.text
.p2align 2

// void* hf_asm_stack_create(uint64_t capacity)  -> ctx / 0
.globl _hf_asm_stack_create
_hf_asm_stack_create:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]
    // capacity 页对齐（16K）/ round to 16K pages.
    add     x19, x0, #0x3, lsl #12      // + 0x3000（imm 上限 4095，分两步）
    add     x19, x19, #0xFFF            // + 0xFFF -> 共 +16383
    and     x19, x19, #0xFFFFFFFFFFFFC000
    add     x0, x19, #64                // + 上下文头 / context header
    bl      _hf_asm_vm_reserve
    cbz     x0, Lsc_out                 // 失败返回 0 / 0 on failure
    add     x9, x0, #64                 // base = ctx + 64
    stp     x9, x19, [x0]               // base, capacity
    mov     x10, #-1
    stp     xzr, x10, [x0, #16]         // top = 0, last_payload = NONE
    // stats 已由匿名页清零 / stats already zeroed by anon pages.
Lsc_out:
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// void hf_asm_stack_destroy(void* ctx)
.globl _hf_asm_stack_destroy
_hf_asm_stack_destroy:
    ldr     x1, [x0, #8]
    add     x1, x1, #64
    b       _hf_asm_vm_release          // 尾调用 / tail call

// void* hf_asm_stack_alloc(void* ctx, uint64_t size)  -> ptr / 0
.globl _hf_asm_stack_alloc
_hf_asm_stack_alloc:
    ldp     x2, x3, [x0]                // base, capacity
    ldp     x4, x5, [x0, #16]           // top, last_payload
    // hdr_at = align16(top); payload = hdr_at + 16.
    add     x6, x4, #15
    and     x6, x6, #0xFFFFFFFFFFFFFFF0
    add     x7, x6, #16                 // payload（16 对齐 / 16-aligned）
    add     x8, x7, x1                  // new_top
    cmp     x8, x3
    b.hi    Lsa_fail                    // 超出容量 / out of capacity
    add     x9, x2, x7                  // 用户指针 / user pointer
    stp     x4, x5, [x9, #-16]          // 帧头: prev_top, prev_payload
    stp     x8, x7, [x0, #16]           // top = new_top, last_payload = payload
    ldr     x10, [x0, #32]
    add     x10, x10, #1
    str     x10, [x0, #32]              // alloc_calls++
    mov     x0, x9
    ret
Lsa_fail:
    mov     x0, xzr
    ret

// int64_t hf_asm_stack_free(void* ctx, void* ptr)  -> 0 / -1(非 LIFO)
.globl _hf_asm_stack_free
_hf_asm_stack_free:
    ldr     x2, [x0]                    // base
    sub     x3, x1, x2                  // payload 偏移 / payload offset
    ldr     x4, [x0, #24]               // last_payload
    cmp     x3, x4
    b.ne    Lsf_bad                     // 只允许 LIFO / LIFO only
    ldp     x5, x6, [x1, #-16]          // prev_top, prev_payload
    stp     x5, x6, [x0, #16]
    ldr     x7, [x0, #40]
    add     x7, x7, #1
    str     x7, [x0, #40]               // free_calls++
    mov     x0, xzr
    ret
Lsf_bad:
    mov     x0, #-1
    ret

// uint64_t hf_asm_stack_mark(void* ctx)  -> 当前水位 / current top
.globl _hf_asm_stack_mark
_hf_asm_stack_mark:
    ldr     x0, [x0, #16]
    ret

// void hf_asm_stack_rewind(void* ctx, uint64_t marker)
.globl _hf_asm_stack_rewind
_hf_asm_stack_rewind:
    mov     x2, #-1
    stp     x1, x2, [x0, #16]           // top = marker, last_payload = NONE
    ret

// uint64_t hf_asm_stack_used(void* ctx)
.globl _hf_asm_stack_used
_hf_asm_stack_used:
    ldr     x0, [x0, #16]
    ret
