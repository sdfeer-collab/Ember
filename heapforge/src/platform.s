// HeapForge (ASM) - 平台层 / Platform layer.
// macOS arm64 裸系统调用：syscall 号放 x16（BSD 类 0x2000000），svc #0x80 陷入；
// 出错时 carry 标志置位。不依赖 libc。
// Raw Mach BSD syscalls: number in x16, trap via svc #0x80, carry set on error.
// No libc dependency. macOS arm64 (Apple Silicon) only.

.text
.p2align 2

// ---------------------------------------------------------------
// void* hf_asm_vm_reserve(uint64_t len)
// 匿名可读写映射；失败返回 0 / anonymous RW mapping, 0 on failure.
// ---------------------------------------------------------------
.globl _hf_asm_vm_reserve
_hf_asm_vm_reserve:
    mov     x1, x0                  // len
    mov     x0, xzr                 // addr = NULL（内核选址 / kernel picks）
    mov     w2, #0x3                // PROT_READ | PROT_WRITE
    mov     w3, #0x1002             // MAP_ANON | MAP_PRIVATE
    mov     x4, #-1                 // fd
    mov     x5, xzr                 // offset
    mov     x16, #0x00C5            // SYS_mmap = 197
    movk    x16, #0x0200, lsl #16   // | 0x2000000 (BSD class)
    svc     #0x80
    b.cs    Lreserve_fail           // carry set = 错误 / error
    ret
Lreserve_fail:
    mov     x0, xzr
    ret

// ---------------------------------------------------------------
// int64_t hf_asm_vm_release(void* ptr, uint64_t len)
// 返回 0 成功 / -1 失败 / 0 on success, -1 on failure.
// ---------------------------------------------------------------
.globl _hf_asm_vm_release
_hf_asm_vm_release:
    mov     x16, #0x0049            // SYS_munmap = 73
    movk    x16, #0x0200, lsl #16
    svc     #0x80
    b.cs    Lrelease_fail
    mov     x0, xzr
    ret
Lrelease_fail:
    mov     x0, #-1
    ret
