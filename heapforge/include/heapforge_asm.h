/* HeapForge (ASM) - C ABI 声明 / C ABI declarations.
 * 核心实现 100% ARM64 汇编（见 src 目录的 .s 文件）；本头文件仅供测试驱动与集成方使用。
 * Core is 100% ARM64 assembly (the .s files under src); this header is for
 * test drivers and consumers. */
#ifndef HEAPFORGE_ASM_H
#define HEAPFORGE_ASM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 平台层 / platform (raw svc syscalls, no libc) ---- */
void*   hf_asm_vm_reserve(uint64_t len);          /* 0 = 失败 / failure */
int64_t hf_asm_vm_release(void* ptr, uint64_t len);

/* ---- 线性栈分配器 / stack allocator ---- */
void*    hf_asm_stack_create(uint64_t capacity);
void     hf_asm_stack_destroy(void* ctx);
void*    hf_asm_stack_alloc(void* ctx, uint64_t size);  /* 16 对齐 / 16-aligned */
int64_t  hf_asm_stack_free(void* ctx, void* ptr);       /* -1 = 非 LIFO */
uint64_t hf_asm_stack_mark(void* ctx);
void     hf_asm_stack_rewind(void* ctx, uint64_t marker);
uint64_t hf_asm_stack_used(void* ctx);

/* ---- 块池 / block pool (bitmap + RBIT/CLZ) ---- */
void*    hf_asm_pool_create(uint64_t block_size, uint64_t block_count);
void     hf_asm_pool_destroy(void* ctx);
void*    hf_asm_pool_alloc(void* ctx);                  /* 0 = 满 / full */
int64_t  hf_asm_pool_free(void* ctx, void* ptr);        /* -1 = 错位/越界/double-free */
uint64_t hf_asm_pool_used(void* ctx);

/* ---- Free List (first-fit + 边界标记合并 / boundary-tag coalescing) ---- */
void*    hf_asm_fl_create(uint64_t capacity);
void     hf_asm_fl_destroy(void* ctx);
void*    hf_asm_fl_alloc(void* ctx, uint64_t size);
int64_t  hf_asm_fl_free(void* ctx, void* ptr);          /* -1 = double-free */
uint64_t hf_asm_fl_free_blocks(void* ctx);              /* 空闲块数 / free blocks */

#ifdef __cplusplus
}
#endif
#endif /* HEAPFORGE_ASM_H */
