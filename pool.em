// pool.em - 试金石 10：Ember 版 BlockPool（对位 heapforge/src/block_pool.s）
// 内存来自 mmap 裸系统调用——不借任何汇编分配器，"零第三方"闭环最后一块
// 上下文布局与汇编版逐字节同构（对拍前提）：
//   [0]=data_base [8]=block_size [16]=block_count [24]=words
//   [32]=bitmap_ptr [40]=hint [48]=used_count [56]=total_len
// 语义对位点：hint 游标 (hint+w)%words 回绕、整字全满跳 64 块、
//   尾字越界位跳字、free 错位/越界/double-free 返 -1、匿名页零初始化
// 汇编版 RBIT+CLZ 找最低空闲位，Ember 版用移位循环——O(64) 换可读性

extern fn mmap(addr: i32, len: i32, prot: i32, flags: i32, fd: i32, off: i32) -> i32;
extern fn munmap(addr: i32, len: i32) -> i32;
extern fn load64(p: i32) -> i32;
extern fn store64(p: i32, v: i32) -> i32;

fn em_pool_create(bs: i32, n: i32) -> i32 {
    let b: i32 = (bs + 15) & ~15;
    let words: i32 = (n + 63) >> 6;
    let doff: i32 = (words * 8 + 79) & ~15;
    let total: i32 = doff + b * n;
    let p: i32 = mmap(0, total, 3, 4098, 0 - 1, 0);
    if p == 0 { return 0; }
    if p == 0 - 1 { return 0; }
    store64(p, p + doff);
    store64(p + 8, b);
    store64(p + 16, n);
    store64(p + 24, words);
    store64(p + 32, p + 64);
    store64(p + 56, total);
    return p;
}

fn em_pool_destroy(ctx: i32) -> i32 {
    return munmap(ctx, load64(ctx + 56));
}

fn em_pool_alloc(ctx: i32) -> i32 {
    let words: i32 = load64(ctx + 24);
    let bm: i32 = load64(ctx + 32);
    let hint: i32 = load64(ctx + 40);
    let w: i32 = 0;
    while w < words {
        let wi: i32 = (hint + w) % words;
        let bits: i32 = load64(bm + (wi << 3));
        let inv: i32 = ~bits;
        if inv != 0 {
            let b: i32 = 0;
            while (inv >> b & 1) == 0 { b = b + 1; }
            let idx: i32 = (wi << 6) + b;
            if idx < load64(ctx + 16) {
                store64(bm + (wi << 3), bits | 1 << b);
                store64(ctx + 40, wi);
                store64(ctx + 48, load64(ctx + 48) + 1);
                return load64(ctx) + idx * load64(ctx + 8);
            }
        }
        w = w + 1;
    }
    return 0;
}

fn em_pool_free(ctx: i32, p: i32) -> i32 {
    let base: i32 = load64(ctx);
    let off: i32 = p - base;
    let bs: i32 = load64(ctx + 8);
    let idx: i32 = off / bs;
    if off % bs != 0 { return 0 - 1; }
    if idx < 0 { return 0 - 1; }
    if idx >= load64(ctx + 16) { return 0 - 1; }
    let bm: i32 = load64(ctx + 32);
    let a: i32 = bm + (idx >> 6 << 3);
    let bits: i32 = load64(a);
    let mask: i32 = 1 << (idx & 63);
    if (bits & mask) == 0 { return 0 - 1; }
    store64(a, bits & ~mask);
    store64(ctx + 40, idx >> 6);
    store64(ctx + 48, load64(ctx + 48) - 1);
    return 0;
}

fn em_pool_used(ctx: i32) -> i32 {
    return load64(ctx + 48);
}
