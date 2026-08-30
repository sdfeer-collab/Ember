// HeapForge (ASM) - 块池 / Block Pool.
// 位图管理固定子块；RBIT+CLZ 两条指令定位 64 位字中最低空闲位，
// 整字全满一次跳过 64 块；hint 游标从上次操作的字继续。
// Bitmap-managed fixed blocks; RBIT+CLZ finds the lowest free bit of a
// 64-bit word; a full word skips 64 blocks at once; hint cursor resumes.
//
// 上下文布局 / context layout (offsets):
//   0: data_base (绝对地址 / absolute)
//   8: block_size
//  16: block_count
//  24: words        (位图 u64 数 / bitmap words)
//  32: bitmap_ptr   (绝对地址 / absolute)
//  40: hint         (字号 / word index)
//  48: used_count
//  56: total_len    (整个映射字节数 / whole mapping size)

.text
.p2align 2

// void* hf_asm_pool_create(uint64_t block_size, uint64_t block_count) -> ctx / 0
.globl _hf_asm_pool_create
_hf_asm_pool_create:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    // bs = align16(block_size) / round block size to 16.
    add     x19, x0, #15
    and     x19, x19, #0xFFFFFFFFFFFFFFF0
    mov     x20, x1                     // count
    // words = (count + 63) / 64
    add     x21, x20, #63
    lsr     x21, x21, #6
    // data_off = align16(64 + words*8)（64B 头 + 位图 / header + bitmap）
    lsl     x22, x21, #3
    add     x22, x22, #79
    and     x22, x22, #0xFFFFFFFFFFFFFFF0
    // total = data_off + bs * count
    mul     x9, x19, x20
    add     x0, x22, x9
    str     x0, [sp, #-16]!             // 暂存 total / stash total
    bl      _hf_asm_vm_reserve
    ldr     x10, [sp], #16              // 恢复 total / restore total
    cbz     x0, Lpc_out
    // 填上下文（匿名页已零：hint/used 不必写）/ fill context.
    add     x9, x0, x22                 // data_base
    stp     x9, x19, [x0]               // data_base, block_size
    stp     x20, x21, [x0, #16]         // block_count, words
    add     x9, x0, #64                 // bitmap_ptr
    str     x9, [x0, #32]
    str     x10, [x0, #56]              // total_len
Lpc_out:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

// void hf_asm_pool_destroy(void* ctx)
.globl _hf_asm_pool_destroy
_hf_asm_pool_destroy:
    ldr     x1, [x0, #56]
    b       _hf_asm_vm_release          // 尾调用 / tail call

// void* hf_asm_pool_alloc(void* ctx) -> ptr / 0
.globl _hf_asm_pool_alloc
_hf_asm_pool_alloc:
    ldr     x2, [x0, #24]               // words
    ldr     x3, [x0, #32]               // bitmap
    ldr     x4, [x0, #40]               // hint
    mov     x5, xzr                     // w = 0
Lpa_scan:
    cmp     x5, x2
    b.hs    Lpa_full
    add     x6, x4, x5                  // hint + w
    udiv    x7, x6, x2
    msub    x6, x7, x2, x6              // wi = (hint+w) % words
    ldr     x7, [x3, x6, lsl #3]        // bits
    mvn     x8, x7
    cbz     x8, Lpa_next                // 整字全满，跳 64 块 / full word
    rbit    x9, x8                      // 最低 0 位 = CTZ(~bits)
    clz     x9, x9                      //   = CLZ(RBIT(~bits))
    lsl     x10, x6, #6
    add     x10, x10, x9                // idx = wi*64 + bit
    ldr     x11, [x0, #16]              // block_count
    cmp     x10, x11
    b.hs    Lpa_next                    // 末字尾部越界位 / tail bits
    mov     x12, #1
    lsl     x12, x12, x9
    orr     x7, x7, x12                 // 置位 / set the bit
    str     x7, [x3, x6, lsl #3]
    str     x6, [x0, #40]               // hint = wi
    ldr     x12, [x0, #48]
    add     x12, x12, #1
    str     x12, [x0, #48]              // used++
    ldr     x11, [x0, #8]               // block_size
    ldr     x13, [x0]                   // data_base
    madd    x0, x10, x11, x13           // ptr = base + idx*bs
    ret
Lpa_next:
    add     x5, x5, #1
    b       Lpa_scan
Lpa_full:
    mov     x0, xzr
    ret

// int64_t hf_asm_pool_free(void* ctx, void* ptr) -> 0 / -1(错位·越界·double-free)
.globl _hf_asm_pool_free
_hf_asm_pool_free:
    ldr     x2, [x0]                    // data_base
    sub     x3, x1, x2                  // off
    ldr     x4, [x0, #8]                // block_size
    udiv    x5, x3, x4                  // idx
    msub    x6, x5, x4, x3
    cbnz    x6, Lpf_bad                 // 未按块对齐 / misaligned
    ldr     x7, [x0, #16]
    cmp     x5, x7
    b.hs    Lpf_bad                     // 越界 / out of range
    lsr     x8, x5, #6                  // word
    and     x9, x5, #63                 // bit
    ldr     x10, [x0, #32]
    ldr     x11, [x10, x8, lsl #3]
    mov     x12, #1
    lsl     x12, x12, x9
    tst     x11, x12
    b.eq    Lpf_bad                     // 位已 0 = double-free
    bic     x11, x11, x12
    str     x11, [x10, x8, lsl #3]
    str     x8, [x0, #40]               // hint = word（就近复用 / reuse nearby）
    ldr     x12, [x0, #48]
    sub     x12, x12, #1
    str     x12, [x0, #48]              // used--
    mov     x0, xzr
    ret
Lpf_bad:
    mov     x0, #-1
    ret

// uint64_t hf_asm_pool_used(void* ctx)
.globl _hf_asm_pool_used
_hf_asm_pool_used:
    ldr     x0, [x0, #48]
    ret
