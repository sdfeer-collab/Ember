// lexer.em - 自读词法器：统计自身源码 Token 数，退出码 = 计数 mod 256
// Project Basilisk 第三阶段试金石 1：第一个"阅读自己"的 Ember 程序
//
// 方言说明（种子 2.95 版 Ember 没有 && || break continue）：
//   a && b   ->  (a) * (b)          比较结果恒为 0/1，乘积即逻辑与
//   a || b   ->  0 < (a) + (b)      和大于 0 即逻辑或
//   continue ->  handled 标志 + if/else 链
//   break    ->  循环条件带标志：while (go == 1) * (i < len) == 1
//
// Token 规则（与规格一致）：
//   标识符 [A-Za-z_][A-Za-z0-9_]*    数字 [0-9]+
//   双字符 == != <= >=               单字符 {}()+-*/=;,<>
//   空白与 // 行注释忽略，未知字符跳过

extern fn open(path: i32, flags: i32) -> i32;
extern fn read(fd: i32, buf: i32, len: i32) -> i32;
extern fn write(fd: i32, buf: i32, len: i32) -> i32;
extern fn close(fd: i32) -> i32;
extern fn load8(ptr: i32) -> i32;
extern fn store8(ptr: i32, val: i32) -> i32;
extern "C" fn hf_asm_pool_create(block_size: i32, block_count: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;
extern "C" fn hf_asm_pool_destroy(pool: i32) -> i32;

static path: [i8] = "lexer.em";
static numbuf: [i8] = "            ";   // 12 字节固定缓冲，print_int 倒序填写
static nl: [i8] = "\n";

fn is_alpha(c: i32) -> i32 {
    return 0 < (65 <= c) * (c <= 90) + (97 <= c) * (c <= 122) + (c == 95);
}

fn is_digit(c: i32) -> i32 {
    return (48 <= c) * (c <= 57);
}

fn is_ws(c: i32) -> i32 {
    return 0 < (c == 32) + (c == 10) + (c == 13) + (c == 9);
}

fn is_two_start(c: i32) -> i32 {
    return 0 < (c == 61) + (c == 33) + (c == 60) + (c == 62);
}

fn is_single(c: i32) -> i32 {
    return 0 < (c == 123) + (c == 125) + (c == 40) + (c == 41) + (c == 43) + (c == 45) + (c == 42) + (c == 47) + (c == 61) + (c == 59) + (c == 44) + (c == 60) + (c == 62);
}

// print_int：正整数转十进制写 stdout（依赖 2.96 的 / 与 %）
fn print_int(num: i32) -> i32 {
    if num == 0 {
        store8(numbuf, 48);
        write(1, numbuf, 1);
        return 0;
    }
    let n: i32 = num;
    let idx: i32 = 12;
    while n > 0 {
        idx = idx - 1;
        let d: i32 = n % 10;
        store8(numbuf + idx, d + 48);
        n = n / 10;
    }
    write(1, numbuf + idx, 12 - idx);
    return 0;
}

fn main() -> i32 {
    let pool: i32 = hf_asm_pool_create(8192, 1);
    if pool == 0 { return 255; }
    let buf: i32 = hf_asm_pool_alloc(pool);
    if buf == 0 { return 254; }
    let fd: i32 = open(path, 0);
    if fd < 3 { return 253; }
    let len: i32 = read(fd, buf, 8192);
    close(fd);

    let i: i32 = 0;
    let tokens: i32 = 0;
    let in_comment: i32 = 0;

    while i < len {
        let c: i32 = load8(buf + i);
        if in_comment == 1 {
            if c == 10 { in_comment = 0; }
            i = i + 1;
        } else {
            let handled: i32 = 0;
            if (c == 47) * (i + 1 < len) == 1 {
                if load8(buf + i + 1) == 47 {
                    in_comment = 1;
                    i = i + 2;
                    handled = 1;
                }
            }
            if handled == 0 {
                if is_ws(c) == 1 {
                    i = i + 1;
                    handled = 1;
                }
            }
            if handled == 0 {
                if is_alpha(c) == 1 {
                    let go: i32 = 1;
                    while (go == 1) * (i < len) == 1 {
                        let d: i32 = load8(buf + i);
                        if 0 < is_alpha(d) + is_digit(d) { i = i + 1; } else { go = 0; }
                    }
                    tokens = tokens + 1;
                    handled = 1;
                }
            }
            if handled == 0 {
                if is_digit(c) == 1 {
                    let go2: i32 = 1;
                    while (go2 == 1) * (i < len) == 1 {
                        let e: i32 = load8(buf + i);
                        if is_digit(e) == 1 { i = i + 1; } else { go2 = 0; }
                    }
                    tokens = tokens + 1;
                    handled = 1;
                }
            }
            if handled == 0 {
                if (is_two_start(c) == 1) * (i + 1 < len) == 1 {
                    if load8(buf + i + 1) == 61 {
                        tokens = tokens + 1;
                        i = i + 2;
                        handled = 1;
                    }
                }
            }
            if handled == 0 {
                if is_single(c) == 1 {
                    tokens = tokens + 1;
                    i = i + 1;
                    handled = 1;
                }
            }
            if handled == 0 { i = i + 1; }
        }
    }

    hf_asm_pool_destroy(pool);
    print_int(tokens);
    write(1, nl, 1);
    return tokens;
}
