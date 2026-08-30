// lexer5.em - 表达式解析器：递归下降 + 后缀输出（AST 的线性化形态）
// Project Basilisk 第三阶段试金石 5：第一个"理解结构"的 Ember 程序
// 文法：expr -> term (("+"|"-") term)*
//       term -> factor (("*"|"/"|"%") factor)*
//       factor -> number | ident | "(" expr ")"
// 输出：数字 "<值> NUM"，标识符 "<intern序号> ID"，运算符 "<符号> OP"，每行一个
//
// 规格修正：next_token 三返回值在 Ember 不存在（单返回值）——
//   token 状态入内存单元：state[0:2]=pos [2]=type [3:5]=val（可写静态块，不占池）
//   type：0=EOF 1=ID 2=NUM 其余=符号 ASCII 原值
//   后缀直接流式 write（与"暂存池再输出"字节流一致，省缓冲与游标）
// 前向引用+相互递归已实验验证：种子发射 bl _name，汇编器解析前向标签

extern fn open(path: i32, flags: i32) -> i32;
extern fn read(fd: i32, buf: i32, len: i32) -> i32;
extern fn write(fd: i32, buf: i32, len: i32) -> i32;
extern fn close(fd: i32) -> i32;
extern fn exit(code: i32) -> i32;
extern fn load8(ptr: i32) -> i32;
extern fn store8(ptr: i32, val: i32) -> i32;
extern "C" fn hf_asm_pool_create(block_size: i32, block_count: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;
extern "C" fn hf_asm_pool_destroy(pool: i32) -> i32;

static path: [i8] = "expr.em";
static newline: [i8] = "\n";
static zero: [i8] = "0";
static pbuf: [i8] = "            ";   // print_int 12 字节倒序缓冲
static state: [i8] = "        ";      // token 状态块：[0:2]=pos [2]=type [3:5]=val
static chbuf: [i8] = " ";             // 单字符输出缓冲
static s_num: [i8] = " NUM\n";
static s_id: [i8] = " ID\n";
static s_op: [i8] = " OP\n";
static s_err: [i8] = "parse error\n";

fn is_alpha(c: i32) -> i32 {
    return 0 < (65 <= c) * (c <= 90) + (97 <= c) * (c <= 122) + (c == 95);
}

fn is_digit(c: i32) -> i32 {
    return (48 <= c) * (c <= 57);
}

fn is_ws(c: i32) -> i32 {
    return 0 < (c == 32) + (c == 10) + (c == 13) + (c == 9);
}

fn mem_eq(a: i32, b: i32, n: i32) -> i32 {
    let j: i32 = 0;
    while j < n {
        if load8(a + j) != load8(b + j) { return 0; }
        j = j + 1;
    }
    return 1;
}

// 驻留表（试金石 4 定型件）：表头 2 字节计数，条目 4B = len+off_lo+off_hi+保留
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

fn cur_type() -> i32 {
    return load8(state + 2);
}

fn cur_val() -> i32 {
    return load8(state + 3) + load8(state + 4) * 256;
}

// 扫描下一个 Token 写入 state：跳空白/行注释，数字算值，标识符驻留，符号存 ASCII
fn advance(buf: i32, len: i32, tab: i32) -> i32 {
    let pos: i32 = load8(state) + load8(state + 1) * 256;
    let sk: i32 = 1;
    while sk == 1 {
        sk = 0;
        if pos < len {
            if is_ws(load8(buf + pos)) == 1 {
                pos = pos + 1;
                sk = 1;
            }
        }
        if sk == 0 {
            if pos + 1 < len {
                if (load8(buf + pos) == 47) * (load8(buf + pos + 1) == 47) == 1 {
                    let go: i32 = 1;
                    while (go == 1) * (pos < len) == 1 {
                        if load8(buf + pos) == 10 { go = 0; }
                        pos = pos + 1;
                    }
                    sk = 1;
                }
            }
        }
    }
    let ty: i32 = 0;
    let val: i32 = 0;
    if pos < len {
        let c: i32 = load8(buf + pos);
        if is_digit(c) == 1 {
            ty = 2;
            let go2: i32 = 1;
            while (go2 == 1) * (pos < len) == 1 {
                let d: i32 = load8(buf + pos);
                if is_digit(d) == 1 {
                    val = val * 10 + d - 48;
                    pos = pos + 1;
                } else { go2 = 0; }
            }
        } else {
            if is_alpha(c) == 1 {
                ty = 1;
                let st2: i32 = pos;
                let go3: i32 = 1;
                while (go3 == 1) * (pos < len) == 1 {
                    let d2: i32 = load8(buf + pos);
                    if 0 < is_alpha(d2) + is_digit(d2) { pos = pos + 1; } else { go3 = 0; }
                }
                val = intern(tab, buf, st2, pos - st2);
            } else {
                ty = c;
                pos = pos + 1;
            }
        }
    }
    store8(state, pos % 256);
    store8(state + 1, pos / 256);
    store8(state + 2, ty);
    store8(state + 3, val % 256);
    store8(state + 4, val / 256);
    return 0;
}

fn emit_op(ch: i32) -> i32 {
    store8(chbuf, ch);
    write(1, chbuf, 1);
    write(1, s_op, 4);
    return 0;
}

fn parse_error() -> i32 {
    write(1, s_err, 12);
    exit(1);
    return 0;
}

fn parse_factor(buf: i32, len: i32, tab: i32) -> i32 {
    let ty: i32 = cur_type();
    if ty == 2 {
        print_int(cur_val());
        write(1, s_num, 5);
        advance(buf, len, tab);
        return 0;
    }
    if ty == 1 {
        print_int(cur_val());
        write(1, s_id, 4);
        advance(buf, len, tab);
        return 0;
    }
    if ty == 40 {
        advance(buf, len, tab);
        parse_expr(buf, len, tab);
        if cur_type() == 41 {
            advance(buf, len, tab);
            return 0;
        }
        parse_error();
    }
    parse_error();
    return 0;
}

fn parse_term(buf: i32, len: i32, tab: i32) -> i32 {
    parse_factor(buf, len, tab);
    let go: i32 = 1;
    while go == 1 {
        let ty: i32 = cur_type();
        if 0 < (ty == 42) + (ty == 47) + (ty == 37) {
            advance(buf, len, tab);
            parse_factor(buf, len, tab);
            emit_op(ty);
        } else { go = 0; }
    }
    return 0;
}

fn parse_expr(buf: i32, len: i32, tab: i32) -> i32 {
    parse_term(buf, len, tab);
    let go: i32 = 1;
    while go == 1 {
        let ty: i32 = cur_type();
        if 0 < (ty == 43) + (ty == 45) {
            advance(buf, len, tab);
            parse_term(buf, len, tab);
            emit_op(ty);
        } else { go = 0; }
    }
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

    store8(state, 0);
    store8(state + 1, 0);
    advance(buf, len, tab);
    parse_expr(buf, len, tab);
    if cur_type() != 0 { parse_error(); }

    hf_asm_pool_destroy(pool);
    return 0;
}
