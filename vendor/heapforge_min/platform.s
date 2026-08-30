// ============================================================
// HeapForge 最小子集 — 平台层 / platform layer (vendor 占位)
// 裸 svc 系统调用，无 libc。符号与 include/heapforge_asm.h 一致，
// 可整体替换为你的完整 libheapforge_asm.a。
//   mmap = 197, munmap = 73（BSD 类，x16 = 0x2000000 | n）
// ============================================================

.text

// void* hf_asm_vm_reserve(uint64_t len)   — 0 = 失败
.globl _hf_asm_vm_reserve
.p2align 2
_hf_asm_vm_reserve:
    mov  x1, x0                 // len
    mov  x0, #0                 // addr = NULL
    mov  x2, #3                 // PROT_READ | PROT_WRITE
    mov  x3, #0x1002            // MAP_ANON | MAP_PRIVATE
    mov  x4, #-1                // fd
    mov  x5, #0                 // offset
    movz x16, #197
    movk x16, #0x0200, lsl #16
    svc  #0x80
    b.cc 1f
    mov  x0, #0                 // carry 置位 = 失败
1:  ret

// int64_t hf_asm_vm_release(void* ptr, uint64_t len)
.globl _hf_asm_vm_release
.p2align 2
_hf_asm_vm_release:
    movz x16, #73
    movk x16, #0x0200, lsl #16
    svc  #0x80
    b.cc 1f
    mov  x0, #-1
    ret
1:  mov  x0, #0
    ret
