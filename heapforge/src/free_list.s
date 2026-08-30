// HeapForge (ASM) - Free List 分配器 / Free-list allocator.
// 隐式空闲链表 first-fit：按物理顺序线性扫块；块头 16B = [size|used(bit0)]
// [prev_phys]；释放时与物理前后邻即时合并，碎片不累积。
// Implicit free list, first-fit physical scan. 16B header = [size|used bit0]
// [prev_phys]; frees coalesce with both physical neighbours immediately.
//
// 上下文布局 / context layout (offsets):
//   0: heap_base
//   8: capacity
//  16: alloc_calls
//  24: free_calls
//  32: total_len

.text
.p2align 2

// void* hf_asm_fl_create(uint64_t capacity) -> ctx / 0
.globl _hf_asm_fl_create
_hf_asm_fl_create:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]
    // capacity 页对齐（16K，且 >= 1 页）/ round to 16K pages.
    add     x19, x0, #0x3, lsl #12      // + 0x3000（imm 上限 4095，分两步）
    add     x19, x19, #0xFFF            // + 0xFFF -> 共 +16383
    and     x19, x19, #0xFFFFFFFFFFFFC000
    cmp     x19, #0x4000
    b.hs    1f
    mov     x19, #0x4000
1:
    add     x0, x19, #64
    bl      _hf_asm_vm_reserve
    cbz     x0, Lfc_out
    add     x9, x0, #64                 // heap_base
    stp     x9, x19, [x0]               // base, capacity
    add     x10, x19, #64
    str     x10, [x0, #32]              // total_len
    // 首块：size = capacity, free, prev = 0（页已零）/ first block header.
    str     x19, [x9]
Lfc_out:
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// void hf_asm_fl_destroy(void* ctx)
.globl _hf_asm_fl_destroy
_hf_asm_fl_destroy:
    ldr     x1, [x0, #32]
    b       _hf_asm_vm_release          // 尾调用 / tail call

// void* hf_asm_fl_alloc(void* ctx, uint64_t size) -> ptr / 0
.globl _hf_asm_fl_alloc
_hf_asm_fl_alloc:
    // need = align16(size + 16)，最小 32 / min 32 bytes.
    add     x2, x1, #31
    and     x2, x2, #0xFFFFFFFFFFFFFFF0
    cmp     x2, #32
    b.hs    1f
    mov     x2, #32
1:
    ldp     x3, x4, [x0]                // base, capacity
    add     x4, x3, x4                  // end
    mov     x5, x3                      // c = base
Lfa_loop:
    cmp     x5, x4
    b.hs    Lfa_fail
    ldr     x6, [x5]                    // size_flags
    tbnz    x6, #0, Lfa_skip            // used -> 跳过 / skip
    cmp     x6, x2
    b.lo    Lfa_skip                    // 空闲但太小 / free but too small
    // 命中 / fit found. remain = size - need.
    sub     x7, x6, x2
    cmp     x7, #32
    b.lo    Lfa_nosplit
    // 分裂：剩余部分成为新空闲块 / split off the remainder.
    add     x8, x5, x2                  // split = c + need
    str     x7, [x8]                    // split: size=remain, free
    str     x5, [x8, #8]                // split.prev_phys = c
    add     x9, x5, x6                  // after = c + orig_size
    cmp     x9, x4
    b.hs    2f
    str     x8, [x9, #8]                // after.prev_phys = split
2:
    orr     x6, x2, #1                  // c: size=need, used
    str     x6, [x5]
    b       Lfa_done
Lfa_nosplit:
    orr     x6, x6, #1
    str     x6, [x5]
Lfa_done:
    ldr     x10, [x0, #16]
    add     x10, x10, #1
    str     x10, [x0, #16]              // alloc_calls++
    add     x0, x5, #16                 // 返回 payload / return payload
    ret
Lfa_skip:
    and     x6, x6, #0xFFFFFFFFFFFFFFFE
    add     x5, x5, x6                  // c += block_size
    b       Lfa_loop
Lfa_fail:
    mov     x0, xzr
    ret

// int64_t hf_asm_fl_free(void* ctx, void* ptr) -> 0 / -1(double-free)
.globl _hf_asm_fl_free
_hf_asm_fl_free:
    sub     x2, x1, #16                 // h = ptr - 16
    ldr     x3, [x2]
    tbz     x3, #0, Lff_bad             // 未标 used = double-free
    and     x3, x3, #0xFFFFFFFFFFFFFFFE // size
    str     x3, [x2]                    // 清 used / clear used bit
    ldp     x4, x5, [x0]                // base, capacity
    add     x5, x4, x5                  // end
    // ---- 与物理后邻合并 / coalesce with the physical successor ----
    add     x6, x2, x3                  // next
    cmp     x6, x5
    b.hs    Lff_prev
    ldr     x7, [x6]
    tbnz    x7, #0, Lff_prev            // next 在用 / next is used
    add     x3, x3, x7
    str     x3, [x2]                    // size += next.size
    add     x8, x2, x3                  // next-next
    cmp     x8, x5
    b.hs    Lff_prev
    str     x2, [x8, #8]                // 修正 prev_phys / fix back-link
Lff_prev:
    // ---- 与物理前邻合并 / coalesce with the physical predecessor ----
    ldr     x9, [x2, #8]                // prev_phys
    cbz     x9, Lff_end                 // 无前邻（首块）/ first block
    ldr     x10, [x9]
    tbnz    x10, #0, Lff_end            // prev 在用 / prev is used
    add     x10, x10, x3
    str     x10, [x9]                   // prev.size += size
    add     x11, x9, x10                // 合并后的后邻 / block after merge
    cmp     x11, x5
    b.hs    Lff_end
    str     x9, [x11, #8]               // 修正 prev_phys / fix back-link
Lff_end:
    ldr     x12, [x0, #24]
    add     x12, x12, #1
    str     x12, [x0, #24]              // free_calls++
    mov     x0, xzr
    ret
Lff_bad:
    mov     x0, #-1
    ret

// uint64_t hf_asm_fl_free_blocks(void* ctx)
// 统计空闲块数（验证合并正确性）/ count free blocks (verifies coalescing).
.globl _hf_asm_fl_free_blocks
_hf_asm_fl_free_blocks:
    ldp     x1, x2, [x0]                // base, capacity
    add     x2, x1, x2                  // end
    mov     x0, xzr                     // count
Lfb_loop:
    cmp     x1, x2
    b.hs    Lfb_done
    ldr     x3, [x1]
    tbnz    x3, #0, 1f
    add     x0, x0, #1                  // 空闲块 +1 / free block
1:
    and     x3, x3, #0xFFFFFFFFFFFFFFFE
    add     x1, x1, x3
    b       Lfb_loop
Lfb_done:
    ret
