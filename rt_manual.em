// rt_manual.em - Project Basilisk 手动内存运行时（试金石 8）
// emberc -manual 产物链接本库：alloc(n) 分配，编译器在函数尾自动插 rt_free
// 全局状态入可写静态块（Ember 无全局变量的标准范式）：
//   rst [0:8]=池句柄 [8:10]=live 计数 [10:12]=init 标志
// 约束：单对象 ≤64B（池定长块），alloc 必须整体作为 let 初始化式

extern fn load8(ptr: i32) -> i32;
extern fn store8(ptr: i32, val: i32) -> i32;
extern "C" fn hf_asm_pool_create(block_size: i32, block_count: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;
extern "C" fn hf_asm_pool_free(pool: i32, ptr: i32) -> i32;

static rst: [i8] = "                ";

fn rt_get16(a: i32) -> i32 {
    return load8(a) + load8(a + 1) * 256;
}

fn rt_put16(a: i32, v: i32) -> i32 {
    store8(a, v % 256);
    store8(a + 1, v / 256);
    return 0;
}

fn rt_get64(a: i32) -> i32 {
    let v: i32 = 0;
    let j: i32 = 8;
    while j > 0 {
        j = j - 1;
        v = v * 256 + load8(a + j);
    }
    return v;
}

fn rt_put64(a: i32, v: i32) -> i32 {
    let j: i32 = 0;
    let w: i32 = v;
    while j < 8 {
        store8(a + j, w % 256);
        w = w / 256;
        j = j + 1;
    }
    return 0;
}

fn rt_init() -> i32 {
    if rt_get16(rst + 10) == 1 { return 0; }
    let p: i32 = hf_asm_pool_create(64, 512);
    rt_put64(rst, p);
    rt_put16(rst + 8, 0);
    rt_put16(rst + 10, 1);
    return 0;
}

fn alloc(n: i32) -> i32 {
    rt_init();
    if n > 64 { return 0; }
    let p: i32 = hf_asm_pool_alloc(rt_get64(rst));
    if p == 0 { return 0; }
    rt_put16(rst + 8, rt_get16(rst + 8) + 1);
    return p;
}

fn rt_free(p: i32) -> i32 {
    if p == 0 { return 0; }
    if rt_get16(rst + 10) == 0 { return 0; }
    hf_asm_pool_free(rt_get64(rst), p);
    rt_put16(rst + 8, rt_get16(rst + 8) - 1);
    return 0;
}

fn rt_live() -> i32 {
    return rt_get16(rst + 8);
}
