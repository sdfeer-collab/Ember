// pool_drv.em - 试金石 10 对拍驱动（汇编版模板）
// test.sh 用 sed s/hf_asm_pool_/em_pool_/g 生成 Ember 版驱动——逻辑同源
// 输出偏移流（ptr - 首块指针），两实现 diff 零差异即语义等价
// 序列设计：70 连分配（跨位图字）-> 每 3 块释放 -> 10 再分配（hint 复用）
//   -> double-free/错位/越界三负例 -> 小池打满返 0

extern "C" fn hf_asm_pool_create(bs: i32, n: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(ctx: i32) -> i32;
extern "C" fn hf_asm_pool_free(ctx: i32, p: i32) -> i32;
extern "C" fn hf_asm_pool_used(ctx: i32) -> i32;
extern fn write(fd: i32, p: i32, n: i32) -> i32;
extern fn store8(p: i32, v: i32) -> i32;

static zero: [i8] = "0";
static pbuf: [i8] = "            ";
static nl: [i8] = "\n";

fn print_int(num: i32) -> i32 {
    if num == 0 {
        write(1, zero, 1);
        return 0;
    }
    let n: i32 = num;
    let idx: i32 = 12;
    while n > 0 {
        idx = idx - 1;
        let d: i32 = n % 10;
        store8(pbuf + idx, d + 48);
        n = n / 10;
    }
    write(1, pbuf + idx, 12 - idx);
    return 0;
}

fn outn(v: i32) -> i32 {
    print_int(v);
    write(1, nl, 1);
    return 0;
}

fn main() -> i32 {
    let ctx: i32 = hf_asm_pool_create(50, 200);
    let base: i32 = 0;
    let i: i32 = 0;
    while i < 70 {
        let p: i32 = hf_asm_pool_alloc(ctx);
        if i == 0 { base = p; }
        outn(p - base);
        i = i + 1;
    }
    outn(hf_asm_pool_used(ctx));
    i = 0;
    while i < 70 {
        outn(hf_asm_pool_free(ctx, base + i * 64) & 255);
        i = i + 3;
    }
    outn(hf_asm_pool_used(ctx));
    i = 0;
    while i < 10 {
        outn(hf_asm_pool_alloc(ctx) - base);
        i = i + 1;
    }
    outn(hf_asm_pool_used(ctx));
    outn(hf_asm_pool_free(ctx, base) & 255);
    outn(hf_asm_pool_free(ctx, base) & 255);
    outn(hf_asm_pool_free(ctx, base + 1) & 255);
    outn(hf_asm_pool_free(ctx, base + 12800) & 255);
    outn(hf_asm_pool_used(ctx));
    let c2: i32 = hf_asm_pool_create(16, 5);
    let b2: i32 = hf_asm_pool_alloc(c2);
    i = 1;
    while i < 5 {
        outn(hf_asm_pool_alloc(c2) - b2);
        i = i + 1;
    }
    outn(hf_asm_pool_alloc(c2));
    outn(hf_asm_pool_used(c2));
    return 0;
}
