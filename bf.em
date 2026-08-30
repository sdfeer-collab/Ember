// bf.em - Project Basilisk 示范项目：Brainfuck 解释器（纯 Ember）
// 四层语言塔：汇编种子 -> emberc（Ember 自举编译器）-> bf.em -> BF 程序
// 用法：./bf <file.bf>   程序从 argv[1] 文件读入，',' 从 stdin 取输入
// 退出码 = 程序结束时数据指针所指单元的值（便于退出码断言）
// 磁带 16384 单元，单元 8 位回绕；程序上限 16383 字节
// 方言约束照旧：无 &&/||，比较用 (a)*(b)；数字字面量 <= 65535

extern fn load8(ptr: i32) -> i32;
extern fn store8(ptr: i32, val: i32) -> i32;
extern fn load64(ptr: i64) -> i64;
extern fn read(fd: i32, p: i32, n: i32) -> i32;
extern fn write(fd: i32, p: i32, n: i32) -> i32;
extern fn open(path: i32, flags: i32) -> i32;
extern fn close(fd: i32) -> i32;
extern "C" fn hf_asm_pool_create(block_size: i32, block_count: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;

static usage: [i8] = "usage: bf <file.bf>\n";

// 解释执行：prog[0..plen) 指令流，tape 数据带
// '[' 跳转用现场扫描配对（深度计数），不预建跳表——O(n) 但零内存开销
fn bf_run(prog: i32, plen: i32, tape: i32) -> i32 {
    let ip: i32 = 0;
    let dp: i32 = 0;
    while ip < plen {
        let c: i32 = load8(prog + ip);
        if c == 62 { dp = dp + 1; }
        if c == 60 { dp = dp - 1; }
        if c == 43 { store8(tape + dp, (load8(tape + dp) + 1) % 256); }
        if c == 45 { store8(tape + dp, (load8(tape + dp) + 255) % 256); }
        if c == 46 { write(1, tape + dp, 1); }
        if c == 44 {
            if read(0, tape + dp, 1) == 0 { store8(tape + dp, 0); }
        }
        if c == 91 {
            if load8(tape + dp) == 0 {
                let d: i32 = 1;
                while d > 0 {
                    ip = ip + 1;
                    if load8(prog + ip) == 91 { d = d + 1; }
                    if load8(prog + ip) == 93 { d = d - 1; }
                }
            }
        }
        if c == 93 {
            if load8(tape + dp) != 0 {
                let e: i32 = 1;
                while e > 0 {
                    ip = ip - 1;
                    if load8(prog + ip) == 91 { e = e - 1; }
                    if load8(prog + ip) == 93 { e = e + 1; }
                }
            }
        }
        ip = ip + 1;
    }
    return load8(tape + dp);
}

fn main(argc: i32, argv: i64) -> i32 {
    if argc < 2 {
        write(2, usage, 20);
        return 1;
    }
    let pool: i32 = hf_asm_pool_create(16384, 2);
    if pool == 0 { return 255; }
    let prog: i32 = hf_asm_pool_alloc(pool);
    let tape: i32 = hf_asm_pool_alloc(pool);
    if tape == 0 { return 254; }
    let j: i32 = 0;
    while j < 16384 {
        store8(tape + j, 0);
        j = j + 1;
    }
    let path: i64 = load64(argv + 8);
    let fd: i32 = open(path, 0);
    if fd < 3 { return 2; }
    let plen: i32 = read(fd, prog, 16383);
    close(fd);
    return bf_run(prog, plen, tape);
}
