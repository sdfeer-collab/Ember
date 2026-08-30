// parser.em - AST 前序节点流解析器
// Project Basilisk 第三阶段试金石 6：完整文法子集（顶层声明 + 语句 + 表达式）
// 输出：前序节点流，每行一个节点，与 ref_parser.py diff 零差异验收
//
// 规格修正（实现时定死）：
//   1. 前序输出与"不建树"互斥（运算符在操作数之后才被读到）——
//      采用表达式级微树：节点池建小树，语句级 emit 后立即重置池计数
//   2. BINOP 输出符号文本（+ - * / % < > == != <= >=），与验收用例一致（序号表作废）
//   3. 增补 CALL <函数名序号> <实参个数> 节点；factor 支持调用产生式
//   4. expr 顶层补比较层（用例 while x < 10 需要）：expr := add [cmpop add]
// 节点 8B：[0]=kind(1NUM 2ID 3BINOP 4CALL) [1:3]=val [3:5]=lhs [5:7]=rhs/argc [7]=next
// token 状态块 state：[0:2]=pos [2]=type [3:5]=val [5:7]=aux(字符串偏移)
// type：0=EOF 1=ID 2=NUM 10..17=关键字 34=字符串 200..203= == != <= >= 其余=ASCII

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

static path: [i8] = "parser.em";
static space: [i8] = " ";
static newline: [i8] = "\n";
static zero: [i8] = "0";
static pbuf: [i8] = "            ";
static state: [i8] = "        ";
static chbuf: [i8] = " ";
static s_err: [i8] = "parse error\n";

static kw_fn: [i8] = "fn";
static kw_let: [i8] = "let";
static kw_if: [i8] = "if";
static kw_else: [i8] = "else";
static kw_while: [i8] = "while";
static kw_return: [i8] = "return";
static kw_extern: [i8] = "extern";
static kw_static: [i8] = "static";

static s_FN: [i8] = "FN ";
static s_EXT: [i8] = "EXTERN ";
static s_ST: [i8] = "STATIC ";
static s_LET: [i8] = "LET ";
static s_IF: [i8] = "IF\n";
static s_ELSE: [i8] = "ELSE\n";
static s_WH: [i8] = "WHILE\n";
static s_RET: [i8] = "RETURN\n";
static s_AS: [i8] = "ASSIGN ";
static s_ES: [i8] = "EXPR_STMT\n";
static s_BL: [i8] = "BLOCK\n";
static s_BI: [i8] = "BINOP ";
static s_NUM: [i8] = "NUM ";
static s_ID: [i8] = "ID ";
static s_CALL: [i8] = "CALL ";
static s_eq2: [i8] = "==";
static s_ne2: [i8] = "!=";
static s_le2: [i8] = "<=";
static s_ge2: [i8] = ">=";

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

fn get16(a: i32) -> i32 {
    return load8(a) + load8(a + 1) * 256;
}

fn put16(a: i32, v: i32) -> i32 {
    store8(a, v % 256);
    store8(a + 1, v / 256);
    return 0;
}

fn intern(tab: i32, buf: i32, st: i32, len: i32) -> i32 {
    let count: i32 = get16(tab);
    let k: i32 = 0;
    while k < count {
        let e: i32 = tab + 4 + k * 4;
        if load8(e) == len {
            if mem_eq(buf + get16(e + 1), buf + st, len) == 1 {
                return k + 1;
            }
        }
        k = k + 1;
    }
    let e2: i32 = tab + 4 + count * 4;
    store8(e2, len);
    put16(e2 + 1, st);
    let nc: i32 = count + 1;
    put16(tab, nc);
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
    return get16(state + 3);
}

fn cur_aux() -> i32 {
    return get16(state + 5);
}

fn parse_error() -> i32 {
    write(1, s_err, 12);
    exit(1);
    return 0;
}

// 扫描下一个 Token：空白/行注释跳过，标识符 classify+intern，数字算值，
// 字符串（type=34，val=长度 aux=偏移，\x 转义按两字节跳），双字符比较 200..203
fn advance(buf: i32, len: i32, tab: i32) -> i32 {
    let pos: i32 = get16(state);
    let g: i32 = 0;
    let d: i32 = 0;
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
                    g = 1;
                    while (g == 1) * (pos < len) == 1 {
                        if load8(buf + pos) == 10 { g = 0; }
                        pos = pos + 1;
                    }
                    sk = 1;
                }
            }
        }
    }
    let ty: i32 = 0;
    let val: i32 = 0;
    let aux: i32 = 0;
    if pos < len {
        let c: i32 = load8(buf + pos);
        if is_digit(c) == 1 {
            ty = 2;
            g = 1;
            while (g == 1) * (pos < len) == 1 {
                d = load8(buf + pos);
                if is_digit(d) == 1 {
                    val = val * 10 + d - 48;
                    pos = pos + 1;
                } else { g = 0; }
            }
        } else { if is_alpha(c) == 1 {
            let st2: i32 = pos;
            g = 1;
            while (g == 1) * (pos < len) == 1 {
                d = load8(buf + pos);
                if 0 < is_alpha(d) + is_digit(d) { pos = pos + 1; } else { g = 0; }
            }
            ty = classify_ident(buf + st2, pos - st2);
            val = intern(tab, buf, st2, pos - st2);
        } else { if c == 34 {
            ty = 34;
            pos = pos + 1;
            aux = pos;
            g = 1;
            while (g == 1) * (pos < len) == 1 {
                d = load8(buf + pos);
                if d == 34 { g = 0; } else {
                    if d == 92 { pos = pos + 2; } else { pos = pos + 1; }
                }
            }
            val = pos - aux;
            pos = pos + 1;
        } else {
            ty = c;
            pos = pos + 1;
            if 0 < (c == 61) + (c == 33) + (c == 60) + (c == 62) {
                if pos < len {
                    if load8(buf + pos) == 61 {
                        if c == 61 { ty = 200; }
                        if c == 33 { ty = 201; }
                        if c == 60 { ty = 202; }
                        if c == 62 { ty = 203; }
                        pos = pos + 1;
                    }
                }
            }
        } } }
    }
    put16(state, pos);
    store8(state + 2, ty);
    put16(state + 3, val);
    put16(state + 5, aux);
    return 0;
}

fn eat(buf: i32, len: i32, tab: i32, t: i32) -> i32 {
    if cur_type() != t { parse_error(); }
    advance(buf, len, tab);
    return 0;
}

fn new_node(np: i32, kind: i32, val: i32) -> i32 {
    let ix: i32 = get16(np) + 1;
    let a: i32 = np + ix * 8;
    store8(a, kind);
    put16(a + 1, val);
    put16(a + 3, 0);
    put16(a + 5, 0);
    store8(a + 7, 0);
    put16(np, ix);
    return ix;
}

fn emit_binop(v: i32) -> i32 {
    if v == 200 { write(1, s_eq2, 2); return 0; }
    if v == 201 { write(1, s_ne2, 2); return 0; }
    if v == 202 { write(1, s_le2, 2); return 0; }
    if v == 203 { write(1, s_ge2, 2); return 0; }
    store8(chbuf, v);
    write(1, chbuf, 1);
    return 0;
}

fn emit_expr(np: i32, ix: i32) -> i32 {
    let a: i32 = np + ix * 8;
    let k: i32 = load8(a);
    if k == 1 {
        write(1, s_NUM, 4);
        print_int(get16(a + 1));
        write(1, newline, 1);
        return 0;
    }
    if k == 2 {
        write(1, s_ID, 3);
        print_int(get16(a + 1));
        write(1, newline, 1);
        return 0;
    }
    if k == 3 {
        write(1, s_BI, 6);
        emit_binop(get16(a + 1));
        write(1, newline, 1);
        emit_expr(np, get16(a + 3));
        emit_expr(np, get16(a + 5));
        return 0;
    }
    if k == 4 {
        write(1, s_CALL, 5);
        print_int(get16(a + 1));
        write(1, space, 1);
        print_int(get16(a + 5));
        write(1, newline, 1);
        let c: i32 = get16(a + 3);
        while c > 0 {
            emit_expr(np, c);
            c = load8(np + c * 8 + 7);
        }
        return 0;
    }
    return 0;
}

fn parse_call(buf: i32, len: i32, tab: i32, np: i32, id: i32) -> i32 {
    advance(buf, len, tab);
    let ix: i32 = new_node(np, 4, id);
    let argc: i32 = 0;
    let prev: i32 = 0;
    if cur_type() != 41 {
        let go: i32 = 1;
        while go == 1 {
            let a: i32 = parse_expr(buf, len, tab, np);
            argc = argc + 1;
            if prev == 0 {
                put16(np + ix * 8 + 3, a);
            } else {
                store8(np + prev * 8 + 7, a);
            }
            prev = a;
            if cur_type() == 44 { advance(buf, len, tab); } else { go = 0; }
        }
    }
    eat(buf, len, tab, 41);
    put16(np + ix * 8 + 5, argc);
    return ix;
}

fn parse_factor(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    let ty: i32 = cur_type();
    if ty == 2 {
        let n: i32 = new_node(np, 1, cur_val());
        advance(buf, len, tab);
        return n;
    }
    if ty == 1 {
        let id: i32 = cur_val();
        advance(buf, len, tab);
        if cur_type() == 40 {
            return parse_call(buf, len, tab, np, id);
        }
        return new_node(np, 2, id);
    }
    if ty == 40 {
        advance(buf, len, tab);
        let e: i32 = parse_expr(buf, len, tab, np);
        eat(buf, len, tab, 41);
        return e;
    }
    parse_error();
    return 0;
}

fn parse_term(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    let l: i32 = parse_factor(buf, len, tab, np);
    let go: i32 = 1;
    while go == 1 {
        let ty: i32 = cur_type();
        if 0 < (ty == 42) + (ty == 47) + (ty == 37) {
            advance(buf, len, tab);
            let r: i32 = parse_factor(buf, len, tab, np);
            let n: i32 = new_node(np, 3, ty);
            put16(np + n * 8 + 3, l);
            put16(np + n * 8 + 5, r);
            l = n;
        } else { go = 0; }
    }
    return l;
}

fn parse_add(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    let l: i32 = parse_term(buf, len, tab, np);
    let go: i32 = 1;
    while go == 1 {
        let ty: i32 = cur_type();
        if 0 < (ty == 43) + (ty == 45) {
            advance(buf, len, tab);
            let r: i32 = parse_term(buf, len, tab, np);
            let n: i32 = new_node(np, 3, ty);
            put16(np + n * 8 + 3, l);
            put16(np + n * 8 + 5, r);
            l = n;
        } else { go = 0; }
    }
    return l;
}

fn parse_expr(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    let l: i32 = parse_add(buf, len, tab, np);
    let ty: i32 = cur_type();
    if 0 < (ty == 60) + (ty == 62) + (ty == 200) + (ty == 201) + (ty == 202) + (ty == 203) {
        advance(buf, len, tab);
        let r: i32 = parse_add(buf, len, tab, np);
        let n: i32 = new_node(np, 3, ty);
        put16(np + n * 8 + 3, l);
        put16(np + n * 8 + 5, r);
        return n;
    }
    return l;
}

fn parse_block(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    eat(buf, len, tab, 123);
    write(1, s_BL, 6);
    while (cur_type() != 125) * (cur_type() != 0) == 1 {
        parse_stmt(buf, len, tab, np);
    }
    eat(buf, len, tab, 125);
    return 0;
}

fn parse_stmt(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    let ty: i32 = cur_type();
    if ty == 11 {
        advance(buf, len, tab);
        let name: i32 = cur_val();
        eat(buf, len, tab, 1);
        eat(buf, len, tab, 58);
        let tid: i32 = cur_val();
        eat(buf, len, tab, 1);
        eat(buf, len, tab, 61);
        write(1, s_LET, 4);
        print_int(name);
        write(1, space, 1);
        print_int(tid);
        write(1, newline, 1);
        put16(np, 0);
        emit_expr(np, parse_expr(buf, len, tab, np));
        eat(buf, len, tab, 59);
        return 0;
    }
    if ty == 12 {
        advance(buf, len, tab);
        put16(np, 0);
        let e: i32 = parse_expr(buf, len, tab, np);
        write(1, s_IF, 3);
        emit_expr(np, e);
        parse_block(buf, len, tab, np);
        if cur_type() == 13 {
            advance(buf, len, tab);
            write(1, s_ELSE, 5);
            parse_block(buf, len, tab, np);
        }
        return 0;
    }
    if ty == 14 {
        advance(buf, len, tab);
        put16(np, 0);
        let e2: i32 = parse_expr(buf, len, tab, np);
        write(1, s_WH, 6);
        emit_expr(np, e2);
        parse_block(buf, len, tab, np);
        return 0;
    }
    if ty == 15 {
        advance(buf, len, tab);
        write(1, s_RET, 7);
        if cur_type() != 59 {
            put16(np, 0);
            emit_expr(np, parse_expr(buf, len, tab, np));
        }
        eat(buf, len, tab, 59);
        return 0;
    }
    if ty == 1 {
        let id: i32 = cur_val();
        advance(buf, len, tab);
        if cur_type() == 61 {
            advance(buf, len, tab);
            write(1, s_AS, 7);
            print_int(id);
            write(1, newline, 1);
            put16(np, 0);
            emit_expr(np, parse_expr(buf, len, tab, np));
            eat(buf, len, tab, 59);
            return 0;
        }
        if cur_type() == 40 {
            write(1, s_ES, 10);
            put16(np, 0);
            emit_expr(np, parse_call(buf, len, tab, np, id));
            eat(buf, len, tab, 59);
            return 0;
        }
        parse_error();
    }
    if ty == 123 {
        parse_block(buf, len, tab, np);
        return 0;
    }
    parse_error();
    return 0;
}

fn parse_params(buf: i32, len: i32, tab: i32) -> i32 {
    let argc: i32 = 0;
    if cur_type() == 1 {
        let go: i32 = 1;
        while go == 1 {
            eat(buf, len, tab, 1);
            eat(buf, len, tab, 58);
            eat(buf, len, tab, 1);
            argc = argc + 1;
            if cur_type() == 44 { advance(buf, len, tab); } else { go = 0; }
        }
    }
    return argc;
}

fn parse_fn(buf: i32, len: i32, tab: i32, np: i32) -> i32 {
    eat(buf, len, tab, 10);
    let name: i32 = cur_val();
    eat(buf, len, tab, 1);
    eat(buf, len, tab, 40);
    let argc: i32 = parse_params(buf, len, tab);
    eat(buf, len, tab, 41);
    let ret: i32 = 0;
    if cur_type() == 45 {
        advance(buf, len, tab);
        eat(buf, len, tab, 62);
        ret = cur_val();
        eat(buf, len, tab, 1);
    }
    write(1, s_FN, 3);
    print_int(name);
    write(1, space, 1);
    print_int(argc);
    write(1, space, 1);
    print_int(ret);
    write(1, newline, 1);
    parse_block(buf, len, tab, np);
    return 0;
}

fn parse_extern(buf: i32, len: i32, tab: i32) -> i32 {
    eat(buf, len, tab, 16);
    if cur_type() == 34 { advance(buf, len, tab); }
    eat(buf, len, tab, 10);
    let name: i32 = cur_val();
    eat(buf, len, tab, 1);
    eat(buf, len, tab, 40);
    let argc: i32 = parse_params(buf, len, tab);
    eat(buf, len, tab, 41);
    let ret: i32 = 0;
    if cur_type() == 45 {
        advance(buf, len, tab);
        eat(buf, len, tab, 62);
        ret = cur_val();
        eat(buf, len, tab, 1);
    }
    write(1, s_EXT, 7);
    print_int(name);
    write(1, space, 1);
    print_int(argc);
    write(1, space, 1);
    print_int(ret);
    write(1, newline, 1);
    eat(buf, len, tab, 59);
    return 0;
}

fn parse_static(buf: i32, len: i32, tab: i32) -> i32 {
    eat(buf, len, tab, 17);
    let name: i32 = cur_val();
    eat(buf, len, tab, 1);
    eat(buf, len, tab, 58);
    eat(buf, len, tab, 91);
    eat(buf, len, tab, 1);
    eat(buf, len, tab, 93);
    eat(buf, len, tab, 61);
    if cur_type() != 34 { parse_error(); }
    let slen: i32 = cur_val();
    let soff: i32 = cur_aux();
    write(1, s_ST, 7);
    print_int(name);
    write(1, space, 1);
    print_int(slen);
    write(1, space, 1);
    write(1, buf + soff, slen);
    write(1, newline, 1);
    advance(buf, len, tab);
    eat(buf, len, tab, 59);
    return 0;
}

fn main() -> i32 {
    let pool: i32 = hf_asm_pool_create(32768, 3);
    if pool == 0 { return 255; }
    let buf: i32 = hf_asm_pool_alloc(pool);
    let tab: i32 = hf_asm_pool_alloc(pool);
    let np: i32 = hf_asm_pool_alloc(pool);
    if np == 0 { return 254; }
    put16(tab, 0);
    put16(np, 0);
    let fd: i32 = open(path, 0);
    if fd < 3 { return 253; }
    let len: i32 = read(fd, buf, 32767);
    close(fd);

    put16(state, 0);
    advance(buf, len, tab);
    let go: i32 = 1;
    while go == 1 {
        let t: i32 = cur_type();
        if t == 0 { go = 0; } else {
            if t == 16 { parse_extern(buf, len, tab); } else {
                if t == 17 { parse_static(buf, len, tab); } else {
                    if t == 10 { parse_fn(buf, len, tab, np); } else {
                        parse_error();
                    }
                }
            }
        }
    }

    hf_asm_pool_destroy(pool);
    return 0;
}
