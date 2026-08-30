// gc.em - Project Basilisk 标记-清扫 GC 运行时（试金石 9）
// emberc -gc 产物链接本库；本库自身用默认模式编译（运行时不给自己插桩）
// 全局状态块 gst：
//   [0:8]=对象池句柄 [8:16]=表池句柄 [16:24]=对象表指针 [24:32]=根帧表指针
//   [32:34]=对象表条目数 [34:36]=根帧数 [36:38]=init 标志
// 对象表条目 16B：[0:8]=ptr [8:10]=size [10]=mark（0=未标 1=已标 2=空洞）
// 根帧表条目 8B：函数 x29 值；标记阶段保守扫每帧 16 槽（编译器已插帧清零）
// 已知限制（交底）：仅显式 gc_collect；表达式中间值（sp 临时栈/寄存器）不在根集，
//   分配与触发必须在语句边界；对象 ≤64B；指针模糊性可致浮标垃圾（不影响正确性）

extern fn load8(ptr: i32) -> i32;
extern fn store8(ptr: i32, val: i32) -> i32;
extern "C" fn hf_asm_pool_create(block_size: i32, block_count: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;
extern "C" fn hf_asm_pool_free(pool: i32, ptr: i32) -> i32;

static gst: [i8] = "                                        ";

fn gc_get16(a: i32) -> i32 {
    return load8(a) + load8(a + 1) * 256;
}

fn gc_put16(a: i32, v: i32) -> i32 {
    store8(a, v % 256);
    store8(a + 1, v / 256);
    return 0;
}

fn gc_get64(a: i32) -> i32 {
    let v: i32 = 0;
    let j: i32 = 8;
    while j > 0 {
        j = j - 1;
        v = v * 256 + load8(a + j);
    }
    return v;
}

fn gc_put64(a: i32, v: i32) -> i32 {
    let j: i32 = 0;
    let w: i32 = v;
    while j < 8 {
        store8(a + j, w % 256);
        w = w / 256;
        j = j + 1;
    }
    return 0;
}

fn gc_init() -> i32 {
    if gc_get16(gst + 36) == 1 { return 0; }
    gc_put64(gst, hf_asm_pool_create(64, 512));
    let tp: i32 = hf_asm_pool_create(8192, 2);
    gc_put64(gst + 8, tp);
    gc_put64(gst + 16, hf_asm_pool_alloc(tp));
    gc_put64(gst + 24, hf_asm_pool_alloc(tp));
    gc_put16(gst + 32, 0);
    gc_put16(gst + 34, 0);
    gc_put16(gst + 36, 1);
    return 0;
}

fn gc_alloc(n: i32) -> i32 {
    gc_init();
    if n > 64 { return 0; }
    let p: i32 = hf_asm_pool_alloc(gc_get64(gst));
    if p == 0 { return 0; }
    let ot: i32 = gc_get64(gst + 16);
    let c: i32 = gc_get16(gst + 32);
    gc_put64(ot + c * 16, p);
    gc_put16(ot + c * 16 + 8, n);
    store8(ot + c * 16 + 10, 0);
    gc_put16(gst + 32, c + 1);
    return p;
}

fn gc_push_frame(fp: i32) -> i32 {
    gc_init();
    let rt: i32 = gc_get64(gst + 24);
    let c: i32 = gc_get16(gst + 34);
    gc_put64(rt + c * 8, fp);
    gc_put16(gst + 34, c + 1);
    return 0;
}

fn gc_pop_frame() -> i32 {
    gc_put16(gst + 34, gc_get16(gst + 34) - 1);
    return 0;
}

// 值 v 若精确命中对象表某条目的 ptr，标记并 DFS 扫描对象内容
fn gc_mark_value(v: i32) -> i32 {
    if v == 0 { return 0; }
    let ot: i32 = gc_get64(gst + 16);
    let c: i32 = gc_get16(gst + 32);
    let k: i32 = 0;
    while k < c {
        let e: i32 = ot + k * 16;
        if load8(e + 10) == 0 {
            if gc_get64(e) == v {
                store8(e + 10, 1);
                let sz: i32 = gc_get16(e + 8);
                let j: i32 = 0;
                while j + 8 <= sz {
                    gc_mark_value(gc_get64(v + j));
                    j = j + 8;
                }
                return 0;
            }
        }
        k = k + 1;
    }
    return 0;
}

fn gc_collect() -> i32 {
    gc_init();
    let ot: i32 = gc_get64(gst + 16);
    let c: i32 = gc_get16(gst + 32);
    let k: i32 = 0;
    while k < c {
        if load8(ot + k * 16 + 10) == 1 { store8(ot + k * 16 + 10, 0); }
        k = k + 1;
    }
    let rt: i32 = gc_get64(gst + 24);
    let rc: i32 = gc_get16(gst + 34);
    k = 0;
    while k < rc {
        let fp: i32 = gc_get64(rt + k * 8);
        let s: i32 = 1;
        while s <= 16 {
            gc_mark_value(gc_get64(fp - s * 8));
            s = s + 1;
        }
        k = k + 1;
    }
    k = 0;
    while k < c {
        let e2: i32 = ot + k * 16;
        if load8(e2 + 10) == 0 {
            hf_asm_pool_free(gc_get64(gst), gc_get64(e2));
            store8(e2 + 10, 2);
        } else {
            if load8(e2 + 10) == 1 { store8(e2 + 10, 0); }
        }
        k = k + 1;
    }
    return 0;
}

fn gc_live() -> i32 {
    let ot: i32 = gc_get64(gst + 16);
    let c: i32 = gc_get16(gst + 32);
    let n: i32 = 0;
    let k: i32 = 0;
    while k < c {
        if load8(ot + k * 16 + 10) != 2 { n = n + 1; }
        k = k + 1;
    }
    return n;
}
