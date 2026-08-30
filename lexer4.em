// lexer4.em - 符号表驻留词法器：每 Token 输出一行 "<类型码> <行号> <符号表序号>"
// Project Basilisk 第三阶段试金石 4：三列 Token 流——语法分析器的完整输入
// 类型码同 lexer3：1=标识符 2=数字 3=符号 10..17=八关键字
// 序号：标识符/关键字共享一张表，按首次出现顺序从 1 编号；数字/符号填 0
//
// 数据结构修正（相对规格）：Ember 无 64 位存取原语，条目不存指针存偏移——
//   表头 [0:2]=条目数(小端 2 字节)；条目 4 字节 = [len][off_lo][off_hi][保留]
//   count 存表头而非 main 变量：intern 单返回值即可自治（Ember 无全局变量）
// 方言改写同前：&&→(a)*(b)  ||→0<(a)+(b)  continue→handled  break→标志循环

extern fn open(path: i32, flags: i32) -> i32;
extern fn read(fd: i32, buf: i32, len: i32) -> i32;
extern fn write(fd: i32, buf: i32, len: i32) -> i32;
extern fn close(fd: i32) -> i32;
extern fn load8(ptr: i32) -> i32;
extern fn store8(ptr: i32, val: i32) -> i32;
extern "C" fn hf_asm_pool_create(block_size: i32, block_count: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;
extern "C" fn hf_asm_pool_destroy(pool: i32) -> i32;

static path: [i8] = "lexer4.em";
static space: [i8] = " ";
static newline: [i8] = "\n";
static zero: [i8] = "0";
static pbuf: [i8] = "            ";   // 12 字节固定缓冲，print_int 倒序填写

static kw_fn: [i8] = "fn";
static kw_let: [i8] = "let";
static kw_if: [i8] = "if";
static kw_else: [i8] = "else";
static kw_while: [i8] = "while";
static kw_return: [i8] = "return";
static kw_extern: [i8] = "extern";
static kw_static: [i8] = "static";

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
    return 0 < (c == 123) + (c == 125) + (c == 40) + (c == 41) + (c == 43) + (c == 45) + (c == 42) + (c == 47) + (c == 61) + (c == 59) + (c == 44) + (c == 60) + (c == 62) + (c == 37);
}

fn mem_eq(a: i32, b: i32, n: i32) -> i32 {
    let j: i32 = 0;
    while j < n {
        if load8(a + j) != load8(b + j) { return 0; }
        j = j + 1;
    }
    return 1;
}

// 长度感知关键字比较（试金石 3 修正版，ident 不带 \0）
fn kw_match(start: i32, len: i32, kw: i32) -> i32 {
    if mem_eq(start, kw, len) == 0 { return 0; }
    if load8(kw + len) == 0 { return 1; }
    return 0;
}

fn classify_ident(start: i32, len: i32) -> i32 {
    if kw_match(start, len, kw_fn) == 1 { return 10; }
    if kw_match(start, len, kw_let) == 1 { return 11; }
    if kw_match(start, len, kw_if) == 1 { return 12; }
    if kw_match(start, len, kw_else) == 1 { return 13; }
    if kw_match(start, len, kw_while) == 1 { return 14; }
    if kw_match(start, len, kw_return) == 1 { return 15; }
    if kw_match(start, len, kw_extern) == 1 { return 16; }
    if kw_match(start, len, kw_static) == 1 { return 17; }
    return 1;
}

// 驻留：命中返回既有序号（k+1），未命中追加条目返回新序号
// 长度先比（条目首字节即长度，规格中"哈希暂用长度"的落地形态）
fn intern(tab: i32, buf: i32, st: i32, len: i32) -> i32 {
    let count: i32 = load8(tab) + load8(tab + 1) * 256;
    let k: i32 = 0;
    while k < count {
        let e: i32 = tab + 4 + k * 4;
        if load8(e) == len {
            if mem_eq(buf + load8(e + 1) + load8(e + 2) * 256, buf + st, len) == 1 {
                return k + 1;
            }
        }
        k = k + 1;
    }
    let e2: i32 = tab + 4 + count * 4;
    store8(e2, len);
    store8(e2 + 1, st % 256);
    store8(e2 + 2, st / 256);
    let nc: i32 = count + 1;
    store8(tab, nc % 256);
    store8(tab + 1, nc / 256);
    return nc;
}

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

fn print_token(code: i32, line: i32, sym: i32) -> i32 {
    print_int(code);
    write(1, space, 1);
    print_int(line);
    write(1, space, 1);
    print_int(sym);
    write(1, newline, 1);
    return 0;
}

fn main() -> i32 {
    let pool: i32 = hf_asm_pool_create(8192, 2);
    if pool == 0 { return 255; }
    let buf: i32 = hf_asm_pool_alloc(pool);
    if buf == 0 { return 254; }
    let tab: i32 = hf_asm_pool_alloc(pool);
    if tab == 0 { return 252; }
    store8(tab, 0);
    store8(tab + 1, 0);
    let fd: i32 = open(path, 0);
    if fd < 3 { return 253; }
    let len: i32 = read(fd, buf, 8192);
    close(fd);

    let i: i32 = 0;
    let line: i32 = 1;
    let in_comment: i32 = 0;

    while i < len {
        let c: i32 = load8(buf + i);
        if c == 10 { line = line + 1; }
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
                    let st: i32 = i;
                    let go: i32 = 1;
                    while (go == 1) * (i < len) == 1 {
                        let d: i32 = load8(buf + i);
                        if 0 < is_alpha(d) + is_digit(d) { i = i + 1; } else { go = 0; }
                    }
                    print_token(classify_ident(buf + st, i - st), line, intern(tab, buf, st, i - st));
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
                    print_token(2, line, 0);
                    handled = 1;
                }
            }
            if handled == 0 {
                if (is_two_start(c) == 1) * (i + 1 < len) == 1 {
                    if load8(buf + i + 1) == 61 {
                        print_token(3, line, 0);
                        i = i + 2;
                        handled = 1;
                    }
                }
            }
            if handled == 0 {
                if is_single(c) == 1 {
                    print_token(3, line, 0);
                    i = i + 1;
                    handled = 1;
                }
            }
            if handled == 0 { i = i + 1; }
        }
    }

    hf_asm_pool_destroy(pool);
    return 0;
}
