// ============================================================
// Project Basilisk — 第 2.96 阶段种子编译器 / stage-2.96 seed compiler
// 100% 纯 ARM64 汇编，macOS Mach-O，无 libc；内存全部来自 HeapForge。
//
// 文法（i64 阶段，前各阶段的严格超集）：
//   program := (extern_decl | static_decl | fn_decl)+
//   static_decl := "static" ident ":" "[" "i8" "]" "=" string ";"
//   string  := '"' {字节 | \n \t \" \\} '"'   （禁裸控制符；空串合法）
//   extern_decl := "extern" ["\"C\""] "fn" ident "(" [param {"," param}] ")"
//                  ["->" ty] ";"
//   param   := ident [":" ty]
//   ty      := "i32" | "i64"           （i64 = 原生 64 位，指针不截断）
//   fn_decl := "fn" ident "(" [param {"," param}] ")" ["->" ty]
//              "{" stmt* "}"
//   stmt    := "return" expr ";" | "let" ident [":" ty] "=" expr ";"
//            | ident "=" expr ";"
//            | ident "(" [expr {"," expr}] ")" ";"        ← 调用语句
//            | "if" expr "{" stmt* "}" ["else" "{" stmt* "}"]
//            | "while" expr "{" stmt* "}"
//   expr    := add [ ("=="|"!="|"<="|">="|"<"|">") add ]   → 0/1
//   add     := term { ("+"|"-") term }
//   term    := primary { ("*"|"/"|"%") primary }
//   primary := number | ident | ident "(" [expr {"," expr}] ")"
//            | "(" expr ")"
// extern 三形态（按表条目 kind 分派）：
//   系统调用 read/write/open/close/exit → 内联 movz/movk x16 + svc #0x80
//   访存原语 load8/store8 → 内联 ldrb/strb（kind 0x1001/0x1002）
//   load64 → 内联 ldr x0, [x0]（kind 0x1003，64 位全宽读）
//   extern "C" fn 名(...) → AAPCS64 外部函数，生成 bl _名（kind 0）
// 约束：实参最多 8 个（x0-x7）；局部槽位（参数+let）最多 16；
//       数字 0..65535（movz 立即数）；作用域为函数级（let 可遮蔽）。
//
// 输入 input.em，输出 output.s（合法 Mach-O ARM64 汇编）。
//
// 全局寄存器（_main 设定，各辅助例程不得破坏）：
//   x19 = AST 节点池句柄（48B/块）   x20 = 栈分配器句柄
//   x21 = 输入缓冲（读入后转 extern 表） x22 = 解析游标
//   x23 = 输入结束指针               x24 = 输出缓冲基址
//   x25 = 输出写游标                 x26 = 函数链表头
//   x27 = 链表尾 / 当前函数 / fd     x28 = 变量表（解析）/ 标签计数（生成）
//
// AST 节点布局（64B，[40] 统一为 next 兄弟指针）：
//   NK_INT  : [8]=值
//   NK_VAR  : [8]=变量槽位
//   NK_ADD  : [8]=lhs  [16]=rhs [24]=op（1add 2sub 3mul 4div 5mod）
//   NK_CALL : [8]=名字 [16]=名长 [24]=实参链表头 [32]=实参数 [48]=调用号（0=普通 bl）
//   NK_RET  : [8]=表达式
//   NK_FN   : [8]=名字 [16]=名长 [24]=语句链表头 [32]=参数个数 [48]=槽位总数
//   NK_LET  : [8]=槽位 [16]=初值表达式
//   NK_ASN  : [8]=槽位 [16]=表达式
//   NK_IF   : [8]=条件 [16]=then 链表 [24]=else 链表（0 = 无）
//   NK_WHILE: [8]=条件 [16]=循环体链表
//   NK_CMP  : [8]=lhs  [16]=rhs [24]=op（1eq 2ne 3lt 4gt 5le 6ge）
//   NK_EXPR : [8]=表达式（调用语句，结果丢弃）
//   NK_STATIC: [8]=名字 [16]=名长 [24]=串内容（指入输入缓冲，零拷贝）
//             [32]=串原始长 [48]=序号（输出标签 _static_<N>）
//   NK_SADDR: [8]=静态序号（引用处生成 adrp/add 页寻址）
//
// extern 符号表（HeapForge 栈分配 544B，全程存活不回卷，x21 持有）：
//   [0]=条数；[8]=静态串链表头（NK_STATIC 经 [40] 串联）；
//   条目 i 在 [16+32*i] = {名字, 名长, kind, 保留}
//   kind：0=bl（"C"），1..6=BSD 系统调用号，0x1001=ldrb，0x1002=strb，0x1003=ldr64
//
// 变量表（HeapForge 栈分配，272B，每函数 mark/rewind 回卷）：
//   [0]=槽位数；条目 i 在 [16+16*i] = {名字指针, 名长|标志}
//   名长第 63 位 = i64 标志（1 = 原生 64 位槽位；查找时掩掉）
//   槽位 = 参数 + let 变量，帧内偏移 16+8*i；倒序查找实现 let 遮蔽
// ============================================================

.set SYS_exit,  1
.set SYS_read,  3
.set SYS_write, 4
.set SYS_open,  5
.set SYS_close, 6

.set NK_INT,  1
.set NK_VAR,  2
.set NK_ADD,  3
.set NK_CALL, 4
.set NK_RET,  5
.set NK_FN,   6
.set NK_LET,   7
.set NK_ASN,   8
.set NK_IF,    9
.set NK_WHILE, 10
.set NK_CMP,   11
.set NK_EXPR,  12
.set NK_STATIC, 13
.set NK_SADDR,  14

.macro SYSCALL num                  // 裸系统调用：x16 = 0x2000000 | num
    movz x16, #\num
    movk x16, #0x0200, lsl #16
    svc  #0x80
.endm

.macro EXPECT sym, len              // 必须匹配，失败即报语法错误退出
    adrp x0, \sym@PAGE
    add  x0, x0, \sym@PAGEOFF
    mov  x1, #\len
    bl   _expect_kw
.endm

.macro TRY sym, len                 // 尝试匹配：x0 = 1 命中（游标前进）/ 0
    adrp x0, \sym@PAGE
    add  x0, x0, \sym@PAGEOFF
    mov  x1, #\len
    bl   _try_match
.endm

.macro KTRY sym, len                // 关键字尝试匹配（带词边界）
    adrp x0, \sym@PAGE
    add  x0, x0, \sym@PAGEOFF
    mov  x1, #\len
    bl   _try_kw
.endm

.macro KEXPECT sym, len             // 关键字必须匹配（带词边界），失败即死
    adrp x0, \sym@PAGE
    add  x0, x0, \sym@PAGEOFF
    mov  x1, #\len
    bl   _expect_kw_b
.endm

.macro EMIT sym                     // 输出一个常量文本片段
    adrp x0, \sym@PAGE
    add  x0, x0, \sym@PAGEOFF
    mov  x1, #\sym\()_len
    bl   _emit_str
.endm

.text
.globl _main
.p2align 2
_main:
    stp x29, x30, [sp, #-144]!      // [96..143] 为 _main 局部变量区
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]

    // ---- 1) HeapForge：AST 节点池（64B x 8192）+ 线性栈 ----
    mov x0, #64
    mov x1, #8192
    bl  _hf_asm_pool_create
    cbz x0, Lerr_oom
    mov x19, x0

    mov x0, #524288                 // 栈分配器总容量（输入 64K + 输出 256K + 表）
    bl  _hf_asm_stack_create
    cbz x0, Lerr_oom
    mov x20, x0

    mov x0, x20
    mov x1, #65536
    bl  _hf_asm_stack_alloc
    cbz x0, Lerr_oom
    mov x21, x0                     // 输入缓冲

    mov x0, x20
    mov x1, #262144
    bl  _hf_asm_stack_alloc
    cbz x0, Lerr_oom
    mov x24, x0                     // 输出缓冲
    mov x25, x24

    // ---- 2) 读取 input.em ----
    adrp x0, Lpath_in@PAGE
    add  x0, x0, Lpath_in@PAGEOFF
    mov  x1, #0                     // O_RDONLY
    mov  x2, #0
    bl   _sys_open
    tbnz x0, #63, Lerr_open_in
    mov  x27, x0

    mov  x0, x27
    mov  x1, x21
    mov  x2, #65535
    bl   _sys_read
    tbnz x0, #63, Lerr_open_in
    add  x23, x21, x0
    mov  x22, x21

    mov  x0, x27
    bl   _sys_close

    mov  x0, x20                    // extern 符号表（先于函数表分配，不回卷）
    mov  x1, #544
    bl   _hf_asm_stack_alloc
    cbz  x0, Lerr_oom
    mov  x21, x0                    // x21 转为 extern 表指针
    str  xzr, [x21]
    str  xzr, [x21, #8]             // 静态串链表头 = 空

    // ---- 3) 语法分析：(extern_decl | static_decl | fn_decl)+ ----
    mov  x26, #0                    // 函数链表头
    mov  x27, #0                    // 链表尾
Lm_parse_loop:
    bl   _skip_ws
    cmp  x22, x23
    b.hs Lm_parse_done
    KTRY Lkw_extern, 6
    cbnz x0, Lm_extern
    KTRY Lkw_static, 6
    cbnz x0, Lm_static
    EXPECT Lkw_fn, 2

    bl   _lex_ident                 // 函数名
    cbz  x1, Lparse_fail
    str  x0, [sp, #96]
    str  x1, [sp, #104]

    mov  x0, x20                    // 变量表：mark + 分配，函数完再回卷
    bl   _hf_asm_stack_mark
    str  x0, [sp, #112]
    mov  x0, x20
    mov  x1, #272
    bl   _hf_asm_stack_alloc
    cbz  x0, Lerr_oom
    mov  x28, x0
    str  xzr, [x28]                 // 槽位数 = 0

    EXPECT Lkw_lpar, 1
    TRY  Lkw_rpar, 1
    cbnz x0, Lm_params_done
Lm_param_loop:
    bl   _lex_ident
    cbz  x1, Lparse_fail
    ldr  x9, [x28]
    cmp  x9, #8
    b.hs Lerr_arity                 // 第 9 个参数
    add  x10, x28, #16
    add  x10, x10, x9, lsl #4
    stp  x0, x1, [x10]
    add  x9, x9, #1
    str  x9, [x28]
    TRY  Lkw_colon, 1               // 可选类型注解 ": i32 | i64"
    cbz  x0, 1f
    TRY  Lkw_i64, 3
    cbz  x0, 2f
    ldr  x9, [x28]                  // i64：名长第 63 位标记槽位
    add  x10, x28, #16
    add  x10, x10, x9, lsl #4
    ldr  x11, [x10, #8]
    orr  x11, x11, #0x8000000000000000
    str  x11, [x10, #8]
    b    1f
2:  EXPECT Lkw_i32, 3
1:  TRY  Lkw_comma, 1
    cbnz x0, Lm_param_loop
    EXPECT Lkw_rpar, 1
Lm_params_done:
    ldr  x9, [x28]                  // 此刻槽位数 = 参数个数（let 尚未登记）
    str  x9, [sp, #128]
    TRY  Lkw_arrow, 2               // "-> i32 | i64" 可选
    cbz  x0, 1f
    TRY  Lkw_i64, 3
    cbnz x0, 1f
    EXPECT Lkw_i32, 3
1:  EXPECT Lkw_lbrace, 1
    bl   _parse_stmt_list           // 函数体：stmt*
    str  x0, [sp, #120]
    EXPECT Lkw_rbrace, 1

    mov  x0, #NK_FN                 // FN 节点入链
    bl   _new_node
    ldr  x9, [sp, #96]
    str  x9, [x0, #8]
    ldr  x9, [sp, #104]
    str  x9, [x0, #16]
    ldr  x9, [sp, #120]
    str  x9, [x0, #24]
    ldr  x9, [sp, #128]
    str  x9, [x0, #32]              // 参数个数（落栈用）
    ldr  x9, [x28]
    str  x9, [x0, #48]              // 槽位总数（帧大小用）
    cbz  x26, 2f
    str  x0, [x27, #40]
    b    3f
2:  mov  x26, x0
3:  mov  x27, x0

    mov  x0, x20                    // 回卷变量表
    ldr  x1, [sp, #112]
    bl   _hf_asm_stack_rewind
    b    Lm_parse_loop

Lm_extern:                          // extern ["C"] fn 名(参数表) [-> i32] ;
    TRY  Lkw_cabi, 3                // "C" → AAPCS64 bl 形态，名字不限
    str  x0, [sp, #136]
    EXPECT Lkw_fn, 2
    bl   _lex_ident
    cbz  x1, Lparse_fail
    str  x0, [sp, #96]
    str  x1, [sp, #104]
    EXPECT Lkw_lpar, 1
    TRY  Lkw_rpar, 1
    cbnz x0, Lm_ext_pdone
Lm_ext_param:
    bl   _lex_ident                 // 参数仅做语法校验，不入表
    cbz  x1, Lparse_fail
    TRY  Lkw_colon, 1
    cbz  x0, 1f
    TRY  Lkw_i64, 3
    cbnz x0, 1f
    EXPECT Lkw_i32, 3
1:  TRY  Lkw_comma, 1
    cbnz x0, Lm_ext_param
    EXPECT Lkw_rpar, 1
Lm_ext_pdone:
    TRY  Lkw_arrow, 2
    cbz  x0, 2f
    TRY  Lkw_i64, 3
    cbnz x0, 2f
    EXPECT Lkw_i32, 3
2:  EXPECT Lkw_semi, 1
    ldr  x9, [sp, #136]             // "C" 形态：kind=0（bl），不查映射表
    cbz  x9, 3f
    mov  x0, #0
    b    4f
3:  ldr  x0, [sp, #96]              // 内联形态：名字 → 调用号/原语标记
    ldr  x1, [sp, #104]
    bl   _map_extern
    cbz  x0, Lerr_extern
4:  ldr  x9, [x21]                  // 入 extern 表
    cmp  x9, #16
    b.hs Lerr_arity
    add  x10, x21, #16
    add  x10, x10, x9, lsl #5
    ldr  x11, [sp, #96]
    ldr  x12, [sp, #104]
    stp  x11, x12, [x10]
    str  x0, [x10, #16]
    add  x9, x9, #1
    str  x9, [x21]
    b    Lm_parse_loop

Lm_static:                          // static 名 : [ i8 ] = "…" ;
    bl   _lex_ident
    cbz  x1, Lparse_fail
    str  x0, [sp, #96]
    str  x1, [sp, #104]
    EXPECT Lkw_colon, 1
    EXPECT Lkw_lbrk, 1
    EXPECT Lkw_i8, 2
    EXPECT Lkw_rbrk, 1
    EXPECT Lkw_assign, 1
    bl   _scan_strlit               // → 内容指针/原始长（零拷贝，指入输入缓冲）
    str  x0, [sp, #112]
    str  x1, [sp, #120]
    EXPECT Lkw_semi, 1
    str  xzr, [sp, #128]            // 序号 = 已有条数（边走边查重）
    ldr  x9, [x21, #8]
    str  x9, [sp, #136]             // 链表游标
5:  ldr  x9, [sp, #136]
    cbz  x9, 6f
    ldr  x0, [sp, #96]
    ldr  x1, [sp, #104]
    ldr  x2, [x9, #8]
    ldr  x3, [x9, #16]
    bl   _str_eq
    cbnz x0, Lerr_dupstatic
    ldr  x9, [sp, #136]
    ldr  x9, [x9, #40]
    str  x9, [sp, #136]
    ldr  x9, [sp, #128]
    add  x9, x9, #1
    str  x9, [sp, #128]
    b    5b
6:  mov  x0, #NK_STATIC             // 头插入链（序号已定，顺序无关紧要）
    bl   _new_node
    ldr  x9, [sp, #96]
    str  x9, [x0, #8]
    ldr  x9, [sp, #104]
    str  x9, [x0, #16]
    ldr  x9, [sp, #112]
    str  x9, [x0, #24]
    ldr  x9, [sp, #120]
    str  x9, [x0, #32]
    ldr  x9, [sp, #128]
    str  x9, [x0, #48]
    ldr  x9, [x21, #8]
    str  x9, [x0, #40]
    str  x0, [x21, #8]
    b    Lm_parse_loop

Lm_parse_done:
    cbz  x26, Lparse_fail           // 至少一个函数

    // ---- 4) 代码生成：静态数据段先行，再遍历函数链表 ----
    EMIT Fg_head
    ldr  x9, [x21, #8]              // 静态串：.section __DATA,__data 逐条发射
    str  x9, [sp, #96]
Lm_st_emit:
    ldr  x9, [sp, #96]
    cbz  x9, Lm_st_done
    EMIT Fd_sect
    ldr  x9, [sp, #96]
    ldr  x0, [x9, #48]
    bl   _emit_dec
    EMIT Fd_lbl
    ldr  x9, [sp, #96]
    ldr  x0, [x9, #24]
    ldr  x1, [x9, #32]
    bl   _emit_str                  // 原文转写，转义展开交给 as
    EMIT Fd_end
    ldr  x9, [sp, #96]
    ldr  x9, [x9, #40]
    str  x9, [sp, #96]
    b    Lm_st_emit
Lm_st_done:
    EMIT Fd_text                    // 回到代码段
    mov  x27, x26
    mov  x28, #0                    // 输出标签计数器 L0, L1, ...
Lm_gen_loop:
    cbz  x27, Lm_gen_done
    mov  x0, x27
    bl   _gen_fn
    ldr  x27, [x27, #40]
    b    Lm_gen_loop
Lm_gen_done:

    // ---- 5) 写出 output.s ----
    adrp x0, Lpath_out@PAGE
    add  x0, x0, Lpath_out@PAGEOFF
    mov  x1, #0x601                 // O_WRONLY | O_CREAT | O_TRUNC
    mov  x2, #0x1A4                 // 0644
    bl   _sys_open
    tbnz x0, #63, Lerr_open_out
    mov  x27, x0

    mov  x0, x27
    mov  x1, x24
    sub  x2, x25, x24
    bl   _sys_write
    tbnz x0, #63, Lerr_open_out

    mov  x0, x27
    bl   _sys_close

    // ---- 6) 收尾 ----
    mov  x0, #1
    adrp x1, Lmsg_ok@PAGE
    add  x1, x1, Lmsg_ok@PAGEOFF
    mov  x2, #Lmsg_ok_len
    bl   _sys_write

    mov  x0, x19
    bl   _hf_asm_pool_destroy
    mov  x0, x20
    bl   _hf_asm_stack_destroy

    mov  x0, #0
    bl   _sys_exit

// ------------------------------------------------------------
// 错误出口：消息写 stderr，退出码 1
// ------------------------------------------------------------
Lerr_open_in:
    adrp x0, Lmsg_ein@PAGE
    add  x0, x0, Lmsg_ein@PAGEOFF
    mov  x1, #Lmsg_ein_len
    b    _fail
Lerr_open_out:
    adrp x0, Lmsg_eout@PAGE
    add  x0, x0, Lmsg_eout@PAGEOFF
    mov  x1, #Lmsg_eout_len
    b    _fail
Lerr_oom:
    adrp x0, Lmsg_eoom@PAGE
    add  x0, x0, Lmsg_eoom@PAGEOFF
    mov  x1, #Lmsg_eoom_len
    b    _fail
Lerr_range:
    adrp x0, Lmsg_erange@PAGE
    add  x0, x0, Lmsg_erange@PAGEOFF
    mov  x1, #Lmsg_erange_len
    b    _fail
Lerr_arity:
    adrp x0, Lmsg_earity@PAGE
    add  x0, x0, Lmsg_earity@PAGEOFF
    mov  x1, #Lmsg_earity_len
    b    _fail
Lerr_ident:
    adrp x0, Lmsg_eident@PAGE
    add  x0, x0, Lmsg_eident@PAGEOFF
    mov  x1, #Lmsg_eident_len
    b    _fail
Lerr_extern:
    adrp x0, Lmsg_eext@PAGE
    add  x0, x0, Lmsg_eext@PAGEOFF
    mov  x1, #Lmsg_eext_len
    b    _fail
Lerr_str:
    adrp x0, Lmsg_estr@PAGE
    add  x0, x0, Lmsg_estr@PAGEOFF
    mov  x1, #Lmsg_estr_len
    b    _fail
Lerr_dupstatic:
    adrp x0, Lmsg_edup@PAGE
    add  x0, x0, Lmsg_edup@PAGEOFF
    mov  x1, #Lmsg_edup_len
    b    _fail
Lerr_obuf:
    adrp x0, Lmsg_eobuf@PAGE
    add  x0, x0, Lmsg_eobuf@PAGEOFF
    mov  x1, #Lmsg_eobuf_len
    b    _fail
Lerr_internal:
    adrp x0, Lmsg_eint@PAGE
    add  x0, x0, Lmsg_eint@PAGEOFF
    mov  x1, #Lmsg_eint_len
    b    _fail
Lparse_fail:
    adrp x0, Lmsg_eparse@PAGE
    add  x0, x0, Lmsg_eparse@PAGEOFF
    mov  x1, #Lmsg_eparse_len
    b    _fail

.p2align 2
_fail:                              // x0 = 消息, x1 = 长度
    mov  x2, x1
    mov  x1, x0
    mov  x0, #2                     // stderr
    bl   _sys_write
    mov  x0, #1
    bl   _sys_exit

// ------------------------------------------------------------
// 词法（游标约定：x22 = 当前，x23 = 结束）
// ------------------------------------------------------------
.p2align 2
_skip_ws:                           // 跳过空格 / \t / \n / \r 与 // 行注释
1:  cmp  x22, x23
    b.hs 9f
    ldrb w9, [x22]
    cmp  w9, #0x20
    b.eq 2f
    cmp  w9, #0x09
    b.eq 2f
    cmp  w9, #0x0A
    b.eq 2f
    cmp  w9, #0x0D
    b.eq 2f
    cmp  w9, #0x2F                  // '/'：可能是行注释
    b.ne 9f
    add  x10, x22, #1
    cmp  x10, x23
    b.hs 9f
    ldrb w10, [x10]
    cmp  w10, #0x2F
    b.ne 9f                         // 单个 '/' 不是注释，交还调用者
    add  x22, x22, #2               // 吃掉 // 直到行尾
3:  cmp  x22, x23
    b.hs 9f
    ldrb w9, [x22]
    add  x22, x22, #1
    cmp  w9, #0x0A
    b.ne 3b
    b    1b
2:  add  x22, x22, #1
    b    1b
9:  ret

.p2align 2
_try_match:                         // x0 = 字面量, x1 = 长度 → x0 = 1/0
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    bl   _skip_ws
    ldp  x0, x1, [sp, #16]
    add  x9, x22, x1
    cmp  x9, x23
    b.hi 8f
    mov  x10, #0
1:  cmp  x10, x1
    b.hs 2f
    ldrb w11, [x0, x10]
    ldrb w12, [x22, x10]
    cmp  w11, w12
    b.ne 8f
    add  x10, x10, #1
    b    1b
2:  add  x22, x22, x1
    mov  x0, #1
    b    9f
8:  mov  x0, #0
9:  ldp  x29, x30, [sp], #32
    ret

.p2align 2
_expect_kw:                         // try_match 失败即死
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _try_match
    cbz  x0, Lparse_fail
    ldp  x29, x30, [sp], #16
    ret

.p2align 2
_try_kw:                            // 关键字匹配（带词边界）→ x0 = 1/0
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x1, x22, [sp, #16]         // 保存游标，词边界失败时回滚
    bl   _try_match
    cbz  x0, 9f
    cmp  x22, x23                   // 命中：后随字符不得是标识符成分
    b.hs 9f
    ldrb w9, [x22]
    orr  w10, w9, #0x20
    sub  w10, w10, #0x61
    cmp  w10, #25
    b.ls 8f
    sub  w10, w9, #0x30
    cmp  w10, #9
    b.ls 8f
    cmp  w9, #0x5F
    b.ne 9f
8:  ldr  x22, [sp, #24]             // 只是标识符前缀：回滚，判不匹配
    mov  x0, #0
9:  ldp  x29, x30, [sp], #32
    ret

.p2align 2
_expect_kw_b:                       // 关键字必须匹配（带词边界）
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _try_kw
    cbz  x0, Lparse_fail
    ldp  x29, x30, [sp], #16
    ret

.p2align 2
_lex_ident:                         // → x0 = 起始, x1 = 长度（0 = 非标识符）
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _skip_ws
    ldp  x29, x30, [sp], #16
    mov  x0, x22
    mov  x1, #0
    cmp  x22, x23
    b.hs 9f
    ldrb w9, [x22]
    orr  w10, w9, #0x20             // 小写化后判 a-z
    sub  w10, w10, #0x61
    cmp  w10, #25
    b.ls 1f
    cmp  w9, #0x5F                  // '_'
    b.ne 9f
1:  add  x22, x22, #1               // 消费首字符
2:  cmp  x22, x23
    b.hs 3f
    ldrb w9, [x22]
    orr  w10, w9, #0x20
    sub  w10, w10, #0x61
    cmp  w10, #25
    b.ls 1b
    sub  w10, w9, #0x30             // 0-9
    cmp  w10, #9
    b.ls 1b
    cmp  w9, #0x5F
    b.eq 1b
3:  sub  x1, x22, x0
9:  ret

.p2align 2
_parse_number:                      // → x0 = 值（0..65535）
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _skip_ws
    cmp  x22, x23
    b.hs Lparse_fail
    ldrb w9, [x22]
    sub  w9, w9, #0x30
    cmp  w9, #9
    b.hi Lparse_fail
    mov  x0, #0
    mov  x11, #10
1:  cmp  x22, x23
    b.hs 2f
    ldrb w9, [x22]
    sub  w10, w9, #0x30
    cmp  w10, #9
    b.hi 2f
    mul  x0, x0, x11
    add  x0, x0, x10
    mov  x12, #0x10000
    cmp  x0, x12
    b.hs Lerr_range
    add  x22, x22, #1
    b    1b
2:  ldp  x29, x30, [sp], #16
    ret

.p2align 2
_lookup_param:                      // x0 = 名, x1 = 长 → x0 = 槽位 / -1（叶子）
    ldr  x10, [x28]                 // 槽位数；倒序扫描实现 let 遮蔽
1:  cbz  x10, 8f
    sub  x10, x10, #1
    add  x11, x28, #16
    add  x11, x11, x10, lsl #4
    ldp  x12, x13, [x11]            // {名字, 名长|标志}
    and  x13, x13, #0x7FFFFFFFFFFFFFFF  // 掩掉 i64 标志位
    cmp  x13, x1
    b.ne 1b
    mov  x14, #0
2:  cmp  x14, x1
    b.hs 6f                         // 全部相等
    ldrb w15, [x0, x14]
    ldrb w16, [x12, x14]
    cmp  w15, w16
    b.ne 1b
    add  x14, x14, #1
    b    2b
6:  mov  x0, x10
    ret
8:  mov  x0, #-1
    ret

.p2align 2
_scan_strlit:                       // → x0=内容起始 x1=原始长（不含引号）
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _skip_ws
    ldp  x29, x30, [sp], #16
    cmp  x22, x23
    b.hs Lerr_str
    ldrb w9, [x22]
    cmp  w9, #0x22                  // 开引号 '"'
    b.ne Lerr_str
    add  x22, x22, #1
    mov  x0, x22                    // 内容起始
1:  cmp  x22, x23
    b.hs Lerr_str                   // EOF 未闭合
    ldrb w9, [x22]
    cmp  w9, #0x22
    b.eq 9f
    cmp  w9, #0x20
    b.lo Lerr_str                   // 裸控制符（含换行）禁止，须用 \n
    cmp  w9, #0x5C                  // '\' → 校验转义：n t " \
    b.ne 2f
    add  x10, x22, #1
    cmp  x10, x23
    b.hs Lerr_str
    ldrb w11, [x10]
    cmp  w11, #0x6E                 // n
    b.eq 3f
    cmp  w11, #0x74                 // t
    b.eq 3f
    cmp  w11, #0x22                 // "
    b.eq 3f
    cmp  w11, #0x5C                 // \
    b.ne Lerr_str
3:  add  x22, x22, #2
    b    1b
2:  add  x22, x22, #1
    b    1b
9:  sub  x1, x22, x0
    add  x22, x22, #1               // 消费闭引号
    ret

.p2align 2
_lookup_static:                     // x0=名 x1=长 → x0=静态序号 / -1
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    ldr  x9, [x21, #8]
    str  x9, [sp, #32]
1:  ldr  x9, [sp, #32]
    cbz  x9, 8f
    ldp  x0, x1, [sp, #16]
    ldr  x2, [x9, #8]
    ldr  x3, [x9, #16]
    bl   _str_eq
    cbz  x0, 2f
    ldr  x9, [sp, #32]
    ldr  x0, [x9, #48]
    b    9f
2:  ldr  x9, [sp, #32]
    ldr  x9, [x9, #40]
    str  x9, [sp, #32]
    b    1b
8:  mov  x0, #-1
9:  ldp  x29, x30, [sp], #48
    ret

.p2align 2
_str_eq:                            // (x0,x1) vs (x2,x3) → x0 = 1/0（叶子）
    cmp  x1, x3
    b.ne 8f
    mov  x9, #0
1:  cmp  x9, x1
    b.hs 7f
    ldrb w10, [x0, x9]
    ldrb w11, [x2, x9]
    cmp  w10, w11
    b.ne 8f
    add  x9, x9, #1
    b    1b
7:  mov  x0, #1
    ret
8:  mov  x0, #0
    ret

.p2align 2
_map_extern:                        // x0=名 x1=长 → x0=kind（0=不支持）
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    str  xzr, [sp, #32]             // 映射表下标
1:  ldr  x9, [sp, #32]
    cmp  x9, #8
    b.hs 8f
    adrp x10, Lsc_map@PAGE
    add  x10, x10, Lsc_map@PAGEOFF
    add  x10, x10, x9, lsl #3       // 条目 24B = i*8 + i*16
    add  x10, x10, x9, lsl #4
    ldp  x2, x3, [x10]
    ldp  x0, x1, [sp, #16]
    bl   _str_eq
    cbnz x0, 7f
    ldr  x9, [sp, #32]
    add  x9, x9, #1
    str  x9, [sp, #32]
    b    1b
7:  ldr  x9, [sp, #32]
    adrp x10, Lsc_map@PAGE
    add  x10, x10, Lsc_map@PAGEOFF
    add  x10, x10, x9, lsl #3
    add  x10, x10, x9, lsl #4
    ldr  x0, [x10, #16]
    b    9f
8:  mov  x0, #0
9:  ldp  x29, x30, [sp], #48
    ret

.p2align 2
_lookup_extern:                     // x0=名 x1=长 → x0=调用号（0=非 extern）
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    str  xzr, [sp, #32]
1:  ldr  x9, [sp, #32]
    ldr  x10, [x21]                 // extern 表条数
    cmp  x9, x10
    b.hs 8f
    add  x10, x21, #16
    add  x10, x10, x9, lsl #5
    ldp  x2, x3, [x10]
    ldp  x0, x1, [sp, #16]
    bl   _str_eq
    cbnz x0, 7f
    ldr  x9, [sp, #32]
    add  x9, x9, #1
    str  x9, [sp, #32]
    b    1b
7:  ldr  x9, [sp, #32]
    add  x10, x21, #16
    add  x10, x10, x9, lsl #5
    ldr  x0, [x10, #16]
    b    9f
8:  mov  x0, #0
9:  ldp  x29, x30, [sp], #48
    ret

// ------------------------------------------------------------
// 语法分析（递归下降，AST 节点来自 HeapForge 块池）
// ------------------------------------------------------------
.p2align 2
_new_node:                          // x0 = kind → x0 = 节点（next 清零）
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x0, [sp, #16]
    mov  x0, x19
    bl   _hf_asm_pool_alloc
    cbz  x0, Lerr_oom
    ldr  x9, [sp, #16]
    str  x9, [x0]
    str  xzr, [x0, #40]
    ldp  x29, x30, [sp], #32
    ret

.p2align 2
_parse_add:                         // add := term { ("+"|"-") term }，左结合
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=lhs [24]=rhs [32]=op
    bl   _parse_term
    str  x0, [sp, #16]
1:  TRY  Lkw_plus, 1
    cbz  x0, 2f
    mov  x9, #1                     // 1 = add
    b    3f
2:  TRY  Lkw_minus, 1
    cbz  x0, 9f
    mov  x9, #2                     // 2 = sub
3:  str  x9, [sp, #32]
    bl   _parse_term
    str  x0, [sp, #24]
    mov  x0, #NK_ADD
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    ldr  x9, [sp, #24]
    str  x9, [x0, #16]
    ldr  x9, [sp, #32]
    str  x9, [x0, #24]              // op
    str  x0, [sp, #16]
    b    1b
9:  ldr  x0, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

.p2align 2
_parse_term:                        // term := primary { ("*"|"/"|"%") primary }，左结合
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=lhs [24]=rhs [32]=op
    bl   _parse_primary
    str  x0, [sp, #16]
1:  TRY  Lkw_star, 1
    cbz  x0, 2f
    mov  x9, #3                     // 3 = mul
    b    3f
2:  TRY  Lkw_slash, 1
    cbz  x0, 4f
    mov  x9, #4                     // 4 = div
    b    3f
4:  TRY  Lkw_percent, 1
    cbz  x0, 9f
    mov  x9, #5                     // 5 = mod
3:  str  x9, [sp, #32]
    bl   _parse_primary
    str  x0, [sp, #24]
    mov  x0, #NK_ADD
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    ldr  x9, [sp, #24]
    str  x9, [x0, #16]
    ldr  x9, [sp, #32]
    str  x9, [x0, #24]
    str  x0, [sp, #16]
    b    1b
9:  ldr  x0, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

.p2align 2
_parse_expr:                        // expr := add [ cmpop add ]，比较结果 0/1
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=lhs [24]=op [32]=rhs；长符号先试（<= 优先于 <）
    bl   _parse_add
    str  x0, [sp, #16]
    TRY  Lop_eq, 2
    cbz  x0, 1f
    mov  x9, #1
    b    Lpe_op
1:  TRY  Lop_ne, 2
    cbz  x0, 2f
    mov  x9, #2
    b    Lpe_op
2:  TRY  Lop_le, 2
    cbz  x0, 3f
    mov  x9, #5
    b    Lpe_op
3:  TRY  Lop_ge, 2
    cbz  x0, 4f
    mov  x9, #6
    b    Lpe_op
4:  TRY  Lop_lt, 1
    cbz  x0, 5f
    mov  x9, #3
    b    Lpe_op
5:  TRY  Lop_gt, 1
    cbz  x0, 6f
    mov  x9, #4
    b    Lpe_op
6:  ldr  x0, [sp, #16]              // 无比较运算符
    ldp  x29, x30, [sp], #48
    ret
Lpe_op:
    str  x9, [sp, #24]
    bl   _parse_add
    str  x0, [sp, #32]
    mov  x0, #NK_CMP
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    ldr  x9, [sp, #32]
    str  x9, [x0, #16]
    ldr  x9, [sp, #24]
    str  x9, [x0, #24]
    ldp  x29, x30, [sp], #48
    ret

.p2align 2
_parse_stmt_list:                   // stmt* 直到 lookahead "}"（不消费）→ 链表头
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    // 局部：[16]=头 [24]=尾
    str  xzr, [sp, #16]
    str  xzr, [sp, #24]
1:  bl   _skip_ws
    cmp  x22, x23
    b.hs 9f                         // EOF：交给上层 EXPECT "}" 报错
    ldrb w9, [x22]
    cmp  w9, #0x7D                  // '}'
    b.eq 9f
    bl   _parse_stmt
    ldr  x9, [sp, #24]
    cbz  x9, 2f
    str  x0, [x9, #40]
    b    3f
2:  str  x0, [sp, #16]
3:  str  x0, [sp, #24]
    b    1b
9:  ldr  x0, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

.p2align 2
_parse_stmt:                        // 单条语句 → x0 = 节点
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    // 局部：[16]=槽位/名 [24]=名长/表达式 [32]=节点/then [40]=else
    KTRY Lkw_return, 6
    cbz  x0, Lps_let
    bl   _parse_expr                // return expr ;
    str  x0, [sp, #16]
    EXPECT Lkw_semi, 1
    mov  x0, #NK_RET
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    b    Lps_ret

Lps_let:
    KTRY Lkw_let, 3
    cbz  x0, Lps_if
    bl   _lex_ident                 // let ident [: i32 | i64] = expr ;
    cbz  x1, Lparse_fail
    stp  x0, x1, [sp, #16]          // 名字暂存
    str  xzr, [sp, #40]             // i64 标志（默认 0 = i32）
    TRY  Lkw_colon, 1               // 可选类型注解
    cbz  x0, 1f
    TRY  Lkw_i64, 3
    str  x0, [sp, #40]
    cbnz x0, 1f
    EXPECT Lkw_i32, 3
1:  EXPECT Lkw_assign, 1
    bl   _parse_expr                // 初值先解析：init 里新变量不可见
    str  x0, [sp, #32]
    EXPECT Lkw_semi, 1
    ldr  x9, [x28]
    cmp  x9, #16
    b.hs Lerr_arity
    add  x10, x28, #16
    add  x10, x10, x9, lsl #4
    ldp  x11, x12, [sp, #16]
    ldr  x13, [sp, #40]
    lsl  x13, x13, #63              // i64 标志并入名长第 63 位
    orr  x12, x12, x13
    stp  x11, x12, [x10]
    add  x10, x9, #1
    str  x10, [x28]                 // 登记新槽位（此后可见/遮蔽）
    str  x9, [sp, #16]
    mov  x0, #NK_LET
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    ldr  x9, [sp, #32]
    str  x9, [x0, #16]
    ldr  x9, [sp, #40]
    str  x9, [x0, #24]              // [24]=i64 标志
    b    Lps_ret

Lps_if:
    KTRY Lkw_if, 2
    cbz  x0, Lps_while
    bl   _parse_expr                // if expr { stmt* } [else { stmt* }]
    str  x0, [sp, #16]
    EXPECT Lkw_lbrace, 1
    bl   _parse_stmt_list
    str  x0, [sp, #32]
    EXPECT Lkw_rbrace, 1
    str  xzr, [sp, #40]
    KTRY Lkw_else, 4
    cbz  x0, 1f
    EXPECT Lkw_lbrace, 1
    bl   _parse_stmt_list
    str  x0, [sp, #40]
    EXPECT Lkw_rbrace, 1
1:  mov  x0, #NK_IF
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    ldr  x9, [sp, #32]
    str  x9, [x0, #16]
    ldr  x9, [sp, #40]
    str  x9, [x0, #24]
    b    Lps_ret

Lps_while:
    KTRY Lkw_while, 5
    cbz  x0, Lps_assign
    bl   _parse_expr                // while expr { stmt* }
    str  x0, [sp, #16]
    EXPECT Lkw_lbrace, 1
    bl   _parse_stmt_list
    str  x0, [sp, #32]
    EXPECT Lkw_rbrace, 1
    mov  x0, #NK_WHILE
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    ldr  x9, [sp, #32]
    str  x9, [x0, #16]
    b    Lps_ret

Lps_assign:
    bl   _lex_ident                 // ident = expr ;  或  ident(args) ;
    cbz  x1, Lparse_fail
    stp  x0, x1, [sp, #16]
    TRY  Lkw_lpar, 1
    cbz  x0, Lps_asn2
    ldp  x0, x1, [sp, #16]          // 调用语句：结果丢弃
    bl   _parse_call_rest
    str  x0, [sp, #24]
    EXPECT Lkw_semi, 1
    mov  x0, #NK_EXPR
    bl   _new_node
    ldr  x9, [sp, #24]
    str  x9, [x0, #8]
    b    Lps_ret
Lps_asn2:
    ldp  x0, x1, [sp, #16]
    bl   _lookup_param
    tbnz x0, #63, Lerr_ident
    str  x0, [sp, #16]
    EXPECT Lkw_assign, 1
    bl   _parse_expr
    str  x0, [sp, #24]
    EXPECT Lkw_semi, 1
    mov  x0, #NK_ASN
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    add  x10, x28, #16
    add  x10, x10, x9, lsl #4
    ldr  x11, [x10, #8]
    lsr  x11, x11, #63
    str  x11, [x0, #24]             // [24]=i64 标志
    ldr  x9, [sp, #24]
    str  x9, [x0, #16]
Lps_ret:
    ldp  x29, x30, [sp], #64
    ret

.p2align 2
_parse_call_rest:                   // x0=名 x1=长（"(" 已消费）→ x0=CALL 节点
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=名 [24]=长 [32]=节点 [40]=实参尾
    stp  x0, x1, [sp, #16]
    mov  x0, #NK_CALL
    bl   _new_node
    ldp  x9, x10, [sp, #16]
    str  x9, [x0, #8]
    str  x10, [x0, #16]
    str  xzr, [x0, #24]
    str  xzr, [x0, #32]
    str  x0, [sp, #32]
    str  xzr, [sp, #40]
    ldp  x0, x1, [sp, #16]          // extern？→ [48]=调用号（0=普通 bl）
    bl   _lookup_extern
    ldr  x9, [sp, #32]
    str  x0, [x9, #48]
    TRY  Lkw_rpar, 1
    cbnz x0, Lpc_done
Lpc_arg_loop:
    bl   _parse_expr
    ldr  x9, [sp, #40]              // 追加到实参链表
    cbz  x9, 1f
    str  x0, [x9, #40]
    b    2f
1:  ldr  x10, [sp, #32]
    str  x0, [x10, #24]
2:  str  x0, [sp, #40]
    ldr  x10, [sp, #32]
    ldr  x9, [x10, #32]
    add  x9, x9, #1
    str  x9, [x10, #32]
    cmp  x9, #8
    b.hi Lerr_arity
    TRY  Lkw_comma, 1
    cbnz x0, Lpc_arg_loop
    EXPECT Lkw_rpar, 1
Lpc_done:
    ldr  x0, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret

.p2align 2
_parse_primary:                     // number | ident | ident(args) | (expr)
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    // 局部：[16]=名/值 [24]=名长 [32]=节点 [40]=实参链表尾
    bl   _skip_ws
    cmp  x22, x23
    b.hs Lparse_fail
    ldrb w9, [x22]
    cmp  w9, #0x28                  // '(' → 括号表达式
    b.ne 1f
    add  x22, x22, #1
    bl   _parse_expr
    str  x0, [sp, #16]
    EXPECT Lkw_rpar, 1
    ldr  x0, [sp, #16]
    b    Lpp_ret
1:  sub  w10, w9, #0x30
    cmp  w10, #9
    b.hi Lpp_ident

    bl   _parse_number              // 数字字面量
    str  x0, [sp, #16]
    mov  x0, #NK_INT
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    b    Lpp_ret

Lpp_ident:
    bl   _lex_ident
    cbz  x1, Lparse_fail
    stp  x0, x1, [sp, #16]
    TRY  Lkw_lpar, 1
    cbnz x0, Lpp_call

    ldp  x0, x1, [sp, #16]          // 变量引用；未命中再查静态串表
    bl   _lookup_param
    tbnz x0, #63, Lpp_static
    str  x0, [sp, #16]
    mov  x0, #NK_VAR
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    add  x10, x28, #16
    add  x10, x10, x9, lsl #4
    ldr  x11, [x10, #8]
    lsr  x11, x11, #63
    str  x11, [x0, #16]             // [16]=i64 标志
    b    Lpp_ret

Lpp_static:                         // 静态串地址引用（参数优先遮蔽）
    ldp  x0, x1, [sp, #16]
    bl   _lookup_static
    tbnz x0, #63, Lerr_ident
    str  x0, [sp, #16]
    mov  x0, #NK_SADDR
    bl   _new_node
    ldr  x9, [sp, #16]
    str  x9, [x0, #8]
    b    Lpp_ret

Lpp_call:
    ldp  x0, x1, [sp, #16]
    bl   _parse_call_rest
    b    Lpp_ret
Lpp_ret:
    ldp  x29, x30, [sp], #64
    ret

// ------------------------------------------------------------
// 代码生成（遍历 AST，写出 ARM64 汇编文本）
// ------------------------------------------------------------
.p2align 2
_gen_fn:                            // x0 = FN 节点
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=FN 节点 [24]=帧大小 [32]=循环 i
    str  x0, [sp, #16]

    EMIT Fg_globl                   // ".globl _" 名 "\n.p2align 2\n_" 名 ":\n"
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    ldr  x1, [x9, #16]
    bl   _emit_str
    EMIT Fg_lbl
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    ldr  x1, [x9, #16]
    bl   _emit_str
    EMIT Fg_colon

    ldr  x9, [sp, #16]              // 帧 = (16 + 8*槽位总数 + 15) & ~15
    ldr  x10, [x9, #48]
    lsl  x11, x10, #3
    add  x11, x11, #31
    and  x11, x11, #~15
    str  x11, [sp, #24]

    EMIT Fg_pro_a                   // "\tstp x29, x30, [sp, #-" 帧 "]!..."
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT Fg_pro_b

    str  xzr, [sp, #32]             // 参数落栈：str x<i>, [x29, #16+8i]
1:  ldr  x9, [sp, #16]
    ldr  x10, [x9, #32]
    ldr  x11, [sp, #32]
    cmp  x11, x10
    b.hs 2f
    EMIT Fg_strx
    ldr  x0, [sp, #32]
    bl   _emit_dec
    EMIT Fg_strx_b
    ldr  x0, [sp, #32]
    lsl  x0, x0, #3
    add  x0, x0, #16
    bl   _emit_dec
    EMIT F_brk_nl
    ldr  x11, [sp, #32]
    add  x11, x11, #1
    str  x11, [sp, #32]
    b    1b
2:
    ldr  x9, [sp, #16]              // 函数体：语句序列
    ldr  x0, [x9, #24]
    bl   _gen_stmt_list

    ldr  x9, [sp, #16]              // 清偿工程债务：末条顶层语句是 return
    ldr  x9, [x9, #24]              // 时不再发射兜底尾声（消除死代码）
    cbz  x9, 7f                     // 空函数体 → 仍需兜底
5:  ldr  x10, [x9, #40]
    cbz  x10, 6f
    mov  x9, x10
    b    5b
6:  ldr  x10, [x9]
    cmp  x10, #NK_RET
    b.eq 8f
7:  EMIT Fe_ret0                    // 兜底：控制流落空时返回 0
    EMIT Fg_epi_a                   // "\tldp x29, x30, [sp], #" 帧 "\n\tret\n\n"
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT Fg_epi_b
8:  ldp  x29, x30, [sp], #48
    ret

.p2align 2
_gen_stmt_list:                     // x0 = 语句链表头（可为 0）
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x0, [sp, #16]
1:  ldr  x0, [sp, #16]
    cbz  x0, 9f
    bl   _gen_stmt
    ldr  x9, [sp, #16]
    ldr  x9, [x9, #40]
    str  x9, [sp, #16]
    b    1b
9:  ldp  x29, x30, [sp], #32
    ret

.p2align 2
_gen_stmt:                          // x0 = 语句节点（x27 = 当前 FN，x28 = 标签计数）
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=节点 [24]=标签A [32]=标签B
    str  x0, [sp, #16]
    ldr  x9, [x0]
    cmp  x9, #NK_RET
    b.eq Lgs_ret
    cmp  x9, #NK_LET
    b.eq Lgs_store
    cmp  x9, #NK_ASN
    b.eq Lgs_store
    cmp  x9, #NK_IF
    b.eq Lgs_if
    cmp  x9, #NK_WHILE
    b.eq Lgs_while
    cmp  x9, #NK_EXPR
    b.eq Lgs_expr
    b    Lerr_internal

Lgs_ret:                            // 表达式 → x0，内联尾声（语句间 sp 平衡）
    ldr  x0, [x0, #8]
    bl   _gen_expr
    EMIT Fg_epi_a
    ldr  x9, [x27, #48]             // 用当前函数槽位数重算帧大小
    lsl  x0, x9, #3
    add  x0, x0, #31
    and  x0, x0, #~15
    bl   _emit_dec
    EMIT Fg_epi_b
    b    Lgs_done

Lgs_store:                          // let/赋值：expr → x0 → str x0, [x29, #off]
    ldr  x0, [x0, #16]
    bl   _gen_expr
    ldr  x9, [sp, #16]
    ldr  x10, [x9, #24]             // i64 标志
    cbnz x10, Lgs_store64
    EMIT Fg_strx
    mov  x0, #0
    bl   _emit_dec
    EMIT Fg_strx_b
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    lsl  x0, x0, #3
    add  x0, x0, #16
    bl   _emit_dec
    EMIT F_brk_nl
    b    Lgs_done
Lgs_store64:                        // i64 槽位：64 位全宽写
    EMIT Fg_strx64
    mov  x0, #0
    bl   _emit_dec
    EMIT Fg_strx64_b
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    lsl  x0, x0, #3
    add  x0, x0, #16
    bl   _emit_dec
    EMIT F_brk_nl
    b    Lgs_done

Lgs_if:                             // cbz 跳 else/终点，then 尾部 b 终点
    str  x28, [sp, #24]             // 标签A = else 入口（无 else 时即终点）
    add  x28, x28, #1
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _gen_expr                  // 条件 → x0
    EMIT Fc_cbz
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT F_nl
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #16]
    bl   _gen_stmt_list             // then 分支
    ldr  x9, [sp, #16]
    ldr  x9, [x9, #24]
    cbz  x9, 1f
    str  x28, [sp, #32]             // 标签B = 终点
    add  x28, x28, #1
    EMIT Fc_b
    ldr  x0, [sp, #32]
    bl   _emit_dec
    EMIT F_nl
    EMIT Fc_lbl
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT Fg_colon
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #24]
    bl   _gen_stmt_list             // else 分支
    EMIT Fc_lbl
    ldr  x0, [sp, #32]
    bl   _emit_dec
    EMIT Fg_colon
    b    Lgs_done
1:  EMIT Fc_lbl
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT Fg_colon
    b    Lgs_done
Lgs_while:                          // 头标签 : 条件 cbz 出口 : 体 : b 头 : 出口
    str  x28, [sp, #24]             // 标签A = 循环头
    add  x28, x28, #1
    str  x28, [sp, #32]             // 标签B = 出口
    add  x28, x28, #1
    EMIT Fc_lbl
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT Fg_colon
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _gen_expr                  // 条件
    EMIT Fc_cbz
    ldr  x0, [sp, #32]
    bl   _emit_dec
    EMIT F_nl
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #16]
    bl   _gen_stmt_list             // 循环体
    EMIT Fc_b
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT F_nl
    EMIT Fc_lbl
    ldr  x0, [sp, #32]
    bl   _emit_dec
    EMIT Fg_colon
    b    Lgs_done
Lgs_expr:                           // 调用语句：求值后丢弃 x0
    ldr  x0, [x0, #8]
    bl   _gen_expr
Lgs_done:
    ldp  x29, x30, [sp], #48
    ret

.p2align 2
_gen_expr:                          // x0 = 表达式节点（递归，结果在目标 x0）
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    // 局部：[16]=节点 [24]=实参游标/寄存器计数
    str  x0, [sp, #16]
    ldr  x9, [x0]
    cmp  x9, #NK_INT
    b.eq Lge_int
    cmp  x9, #NK_VAR
    b.eq Lge_var
    cmp  x9, #NK_ADD
    b.eq Lge_add
    cmp  x9, #NK_CALL
    b.eq Lge_call
    cmp  x9, #NK_CMP
    b.eq Lge_cmp
    cmp  x9, #NK_SADDR
    b.eq Lge_saddr
    b    Lerr_internal

Lge_int:                            // mov x0, #N
    EMIT Fe_mov
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _emit_dec
    EMIT F_nl
    b    Lge_done

Lge_var:                            // ldr x0, [x29, #16+8i]
    ldr  x9, [sp, #16]
    ldr  x10, [x9, #16]             // i64 标志
    cbnz x10, Lge_var64
    EMIT Fe_ldrvar
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    lsl  x0, x0, #3
    add  x0, x0, #16
    bl   _emit_dec
    EMIT F_brk_nl
    b    Lge_done
Lge_var64:                          // i64 槽位：64 位全宽读
    EMIT Fe_ldrvar64
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    lsl  x0, x0, #3
    add  x0, x0, #16
    bl   _emit_dec
    EMIT F_brk_nl
    b    Lge_done

Lge_add:                            // lhs → 压栈 → rhs → 弹栈 + op 分派
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _gen_expr
    EMIT Fe_push
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #16]
    bl   _gen_expr
    EMIT Fe_pop2                    // "ldr x9, [sp], #16" + 制表符
    ldr  x9, [sp, #16]
    ldr  x9, [x9, #24]              // op：4=div 5=mod 单独分支，1..3 走助记符表
    cmp  x9, #4
    b.eq Lge_div
    cmp  x9, #5
    b.eq Lge_mod
    sub  x9, x9, #1                // op 1..3 → 助记符表 3 字符一条
    adrp x0, Fop3@PAGE
    add  x0, x0, Fop3@PAGEOFF
    add  x10, x9, x9, lsl #1
    add  x0, x0, x10
    mov  x1, #3
    bl   _emit_str
    EMIT Fe_opnds                   // " x0, x9, x0\n"
    b    Lge_done
Lge_div:                            // sdiv x0, x9, x0（被除数 x9 / 除数 x0）
    EMIT Fe_sdiv
    b    Lge_done
Lge_mod:                            // sdiv x10, x9, x0 ; msub x0, x10, x0, x9
    EMIT Fe_smod
    b    Lge_done

Lge_call:                           // 实参逐个求值压栈，倒序弹入 x0..x<n-1>
    ldr  x9, [sp, #16]
    ldr  x9, [x9, #24]
    str  x9, [sp, #24]
1:  ldr  x9, [sp, #24]
    cbz  x9, 2f
    mov  x0, x9
    bl   _gen_expr
    EMIT Fe_push
    ldr  x9, [sp, #24]
    ldr  x9, [x9, #40]
    str  x9, [sp, #24]
    b    1b
2:  ldr  x9, [sp, #16]
    ldr  x9, [x9, #32]              // argc
3:  cbz  x9, 4f
    sub  x9, x9, #1
    str  x9, [sp, #24]
    EMIT Fe_ldrx
    ldr  x0, [sp, #24]
    bl   _emit_dec
    EMIT Fe_popreg
    ldr  x9, [sp, #24]
    b    3b
4:  ldr  x9, [sp, #16]
    ldr  x10, [x9, #48]             // kind：0=bl 0x1001=ldrb 0x1002=strb 其余=svc
    cbnz x10, 5f
    EMIT Fe_bl                      // bl _名
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    ldr  x1, [x9, #16]
    bl   _emit_str
    EMIT F_nl
    b    Lge_done
5:  mov  x11, #0x1001
    cmp  x10, x11
    b.ne 6f
    EMIT Fm_ldrb                    // load8：地址已弹入 x0
    b    Lge_done
6:  mov  x11, #0x1002
    cmp  x10, x11
    b.ne Lgc_chk64
    EMIT Fm_strb                    // store8：x0=地址 x1=值，固定返 0
    b    Lge_done
Lgc_chk64:
    mov  x11, #0x1003
    cmp  x10, x11
    b.ne 7f
    EMIT Fm_ldrq                    // load64：地址已弹入 x0，64 位全宽读
    b    Lge_done
7:  EMIT Fs_movz                    // 系统调用：movz/movk x16 + svc
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #48]
    bl   _emit_dec
    EMIT Fs_svc
    b    Lge_done

Lge_cmp:                            // lhs → 压栈 → rhs → cmp + cset（结果 0/1）
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _gen_expr
    EMIT Fe_push
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #16]
    bl   _gen_expr
    EMIT Fe_popcmp
    ldr  x9, [sp, #16]
    ldr  x9, [x9, #24]              // op 1..6 → 条件名表 2 字符一条
    sub  x9, x9, #1
    adrp x0, Fcond@PAGE
    add  x0, x0, Fcond@PAGEOFF
    add  x0, x0, x9, lsl #1
    mov  x1, #2
    bl   _emit_str
    EMIT F_nl
    b    Lge_done

Lge_saddr:                          // 静态串地址：adrp/add 页寻址
    EMIT Fa_adrp
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _emit_dec
    EMIT Fa_page
    ldr  x9, [sp, #16]
    ldr  x0, [x9, #8]
    bl   _emit_dec
    EMIT Fa_pageoff

Lge_done:
    ldp  x29, x30, [sp], #48
    ret

// ------------------------------------------------------------
// 输出辅助（x25 = 输出写游标，带缓冲越界检查）
// ------------------------------------------------------------
.p2align 2
_emit_str:                          // x0 = 源, x1 = 长度
    mov  x9, #262144
    add  x9, x24, x9
    add  x10, x25, x1
    cmp  x10, x9
    b.hi Lerr_obuf
    cbz  x1, 9f
1:  ldrb w9, [x0], #1
    strb w9, [x25], #1
    subs x1, x1, #1
    b.ne 1b
9:  ret

.p2align 2
_emit_dec:                          // x0 = 无符号值，十进制文本写入输出
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    mov  x10, x0
    add  x11, sp, #40               // 数字缓冲 sp+16..sp+40，倒序填
    mov  x12, #10
1:  udiv x13, x10, x12
    msub x14, x13, x12, x10
    add  w14, w14, #0x30
    sub  x11, x11, #1
    strb w14, [x11]
    mov  x10, x13
    cbnz x10, 1b
    mov  x0, x11
    add  x1, sp, #40
    sub  x1, x1, x11
    bl   _emit_str
    ldp  x29, x30, [sp], #48
    ret

// ------------------------------------------------------------
// 裸系统调用封装（出错统一返回 -1）
// ------------------------------------------------------------
.p2align 2
_sys_open:
    SYSCALL SYS_open
    b.cc 1f
    mov  x0, #-1
1:  ret

.p2align 2
_sys_read:
    SYSCALL SYS_read
    b.cc 1f
    mov  x0, #-1
1:  ret

.p2align 2
_sys_write:
    SYSCALL SYS_write
    b.cc 1f
    mov  x0, #-1
1:  ret

.p2align 2
_sys_close:
    SYSCALL SYS_close
    b.cc 1f
    mov  x0, #-1
1:  ret

.p2align 2
_sys_exit:
    SYSCALL SYS_exit                // 不返回

// ------------------------------------------------------------
// 只读数据
// ------------------------------------------------------------
.section __TEXT,__const
Lpath_in:   .asciz "input.em"
Lpath_out:  .asciz "output.s"

Lkw_fn:     .ascii "fn"
Lkw_i32:    .ascii "i32"
Lkw_i64:    .ascii "i64"
Lkw_return: .ascii "return"
Lkw_arrow:  .ascii "->"
Lkw_lpar:   .ascii "("
Lkw_rpar:   .ascii ")"
Lkw_lbrace: .ascii "{"
Lkw_rbrace: .ascii "}"
Lkw_comma:  .ascii ","
Lkw_semi:   .ascii ";"
Lkw_plus:   .ascii "+"
Lkw_let:    .ascii "let"
Lkw_if:     .ascii "if"
Lkw_while:  .ascii "while"
Lkw_else:   .ascii "else"
Lkw_assign: .ascii "="
Lkw_extern: .ascii "extern"
Lkw_colon:  .ascii ":"
Lkw_minus:  .ascii "-"
Lkw_star:   .ascii "*"
Lkw_slash:  .ascii "/"
Lkw_percent: .ascii "%"
Lkw_cabi:   .ascii "\"C\""
Lkw_static: .ascii "static"
Lkw_i8:     .ascii "i8"
Lkw_lbrk:   .ascii "["
Lkw_rbrk:   .ascii "]"
Lsc_read:   .ascii "read"
Lsc_write:  .ascii "write"
Lsc_open:   .ascii "open"
Lsc_close:  .ascii "close"
Lsc_exit:   .ascii "exit"
Lsc_load8:  .ascii "load8"
Lsc_store8: .ascii "store8"
Lsc_load64: .ascii "load64"

// 指针表含绝对地址重定位，必须放数据段（__TEXT 禁止 text-relocation）
.section __DATA,__const
.p2align 3
Lsc_map:                            // {名字, 名长, kind} x 8
    .quad Lsc_read,   4, 3
    .quad Lsc_write,  5, 4
    .quad Lsc_open,   4, 5
    .quad Lsc_close,  5, 6
    .quad Lsc_exit,   4, 1
    .quad Lsc_load8,  5, 0x1001
    .quad Lsc_store8, 6, 0x1002
    .quad Lsc_load64, 6, 0x1003
.section __TEXT,__const
Lop_eq:     .ascii "=="
Lop_ne:     .ascii "!="
Lop_le:     .ascii "<="
Lop_ge:     .ascii ">="
Lop_lt:     .ascii "<"
Lop_gt:     .ascii ">"
Fcond:      .ascii "eqneltgtlege"   // (op-1)*2 索引，每条 2 字符

// -- 代码生成文本片段 / codegen fragments --
Fg_head:    .ascii "// Generated by Basilisk seed compiler (stage 2.96)\n.text\n"
.set Fg_head_len, . - Fg_head
Fg_globl:   .ascii ".globl _"
.set Fg_globl_len, . - Fg_globl
Fg_lbl:     .ascii "\n.p2align 2\n_"
.set Fg_lbl_len, . - Fg_lbl
Fg_colon:   .ascii ":\n"
.set Fg_colon_len, . - Fg_colon
Fg_pro_a:   .ascii "\tstp x29, x30, [sp, #-"
.set Fg_pro_a_len, . - Fg_pro_a
Fg_pro_b:   .ascii "]!\n\tmov x29, sp\n"
.set Fg_pro_b_len, . - Fg_pro_b
Fg_strx:    .ascii "\tstr x"
.set Fg_strx_len, . - Fg_strx
Fg_strx_b:  .ascii ", [x29, #"
.set Fg_strx_b_len, . - Fg_strx_b
Fg_strx64:  .ascii "\tstr x"                 // i64 槽位专用发射路径
.set Fg_strx64_len, . - Fg_strx64
Fg_strx64_b: .ascii ", [x29, #"
.set Fg_strx64_b_len, . - Fg_strx64_b
Fg_epi_a:   .ascii "\tldp x29, x30, [sp], #"
.set Fg_epi_a_len, . - Fg_epi_a
Fg_epi_b:   .ascii "\n\tret\n\n"
.set Fg_epi_b_len, . - Fg_epi_b
Fe_mov:     .ascii "\tmov x0, #"
.set Fe_mov_len, . - Fe_mov
Fe_ldrvar:  .ascii "\tldr x0, [x29, #"
.set Fe_ldrvar_len, . - Fe_ldrvar
Fe_ldrvar64: .ascii "\tldr x0, [x29, #"      // i64 槽位专用发射路径
.set Fe_ldrvar64_len, . - Fe_ldrvar64
Fe_push:    .ascii "\tstr x0, [sp, #-16]!\n"
.set Fe_push_len, . - Fe_push
Fe_popadd:  .ascii "\tldr x9, [sp], #16\n\tadd x0, x9, x0\n"
.set Fe_popadd_len, . - Fe_popadd
Fe_pop2:    .ascii "\tldr x9, [sp], #16\n\t"
.set Fe_pop2_len, . - Fe_pop2
Fe_opnds:   .ascii " x0, x9, x0\n"
.set Fe_opnds_len, . - Fe_opnds
Fe_sdiv:    .ascii "sdiv x0, x9, x0\n"
.set Fe_sdiv_len, . - Fe_sdiv
Fe_smod:    .ascii "sdiv x10, x9, x0\n\tmsub x0, x10, x0, x9\n"
.set Fe_smod_len, . - Fe_smod
Fop3:       .ascii "addsubmul"      // (op-1)*3 索引，每条 3 字符
Fm_ldrb:    .ascii "\tldrb w0, [x0]\n"
.set Fm_ldrb_len, . - Fm_ldrb
Fm_strb:    .ascii "\tstrb w1, [x0]\n\tmov x0, #0\n"
.set Fm_strb_len, . - Fm_strb
Fm_ldrq:    .ascii "\tldr x0, [x0]\n"
.set Fm_ldrq_len, . - Fm_ldrq
Fd_sect:    .ascii "\n.section __DATA,__data\n_static_"
.set Fd_sect_len, . - Fd_sect
Fd_lbl:     .ascii ": .asciz \""
.set Fd_lbl_len, . - Fd_lbl
Fd_end:     .ascii "\"\n"
.set Fd_end_len, . - Fd_end
Fd_text:    .ascii "\n.text\n"
.set Fd_text_len, . - Fd_text
Fa_adrp:    .ascii "\tadrp x0, _static_"
.set Fa_adrp_len, . - Fa_adrp
Fa_page:    .ascii "@PAGE\n\tadd x0, x0, _static_"
.set Fa_page_len, . - Fa_page
Fa_pageoff: .ascii "@PAGEOFF\n"
.set Fa_pageoff_len, . - Fa_pageoff
Fe_ldrx:    .ascii "\tldr x"
.set Fe_ldrx_len, . - Fe_ldrx
Fe_popreg:  .ascii ", [sp], #16\n"
.set Fe_popreg_len, . - Fe_popreg
Fe_bl:      .ascii "\tbl _"
.set Fe_bl_len, . - Fe_bl
F_nl:       .ascii "\n"
.set F_nl_len, . - F_nl
F_brk_nl:   .ascii "]\n"
.set F_brk_nl_len, . - F_brk_nl
Fe_popcmp:  .ascii "\tldr x9, [sp], #16\n\tcmp x9, x0\n\tcset x0, "
.set Fe_popcmp_len, . - Fe_popcmp
Fe_ret0:    .ascii "\tmov x0, #0\n"
.set Fe_ret0_len, . - Fe_ret0
Fc_cbz:     .ascii "\tcbz x0, L"
.set Fc_cbz_len, . - Fc_cbz
Fc_b:       .ascii "\tb L"
.set Fc_b_len, . - Fc_b
Fc_lbl:     .ascii "L"
.set Fc_lbl_len, . - Fc_lbl
Fs_movz:    .ascii "\tmovz x16, #"
.set Fs_movz_len, . - Fs_movz
Fs_svc:     .ascii "\n\tmovk x16, #0x0200, lsl #16\n\tsvc #0x80\n"
.set Fs_svc_len, . - Fs_svc

// -- 诊断消息 / diagnostics --
Lmsg_ok:     .ascii "basilisk-seed: wrote output.s\n"
.set Lmsg_ok_len, . - Lmsg_ok
Lmsg_ein:    .ascii "basilisk-seed: error: cannot open/read input.em\n"
.set Lmsg_ein_len, . - Lmsg_ein
Lmsg_eout:   .ascii "basilisk-seed: error: cannot write output.s\n"
.set Lmsg_eout_len, . - Lmsg_eout
Lmsg_eoom:   .ascii "basilisk-seed: error: HeapForge allocation failed\n"
.set Lmsg_eoom_len, . - Lmsg_eoom
Lmsg_eparse: .ascii "basilisk-seed: parse error: bad declaration or statement\n"
.set Lmsg_eparse_len, . - Lmsg_eparse
Lmsg_erange: .ascii "basilisk-seed: error: integer out of range (max 65535)\n"
.set Lmsg_erange_len, . - Lmsg_erange
Lmsg_earity: .ascii "basilisk-seed: error: too many args (max 8) or locals (max 16)\n"
.set Lmsg_earity_len, . - Lmsg_earity
Lmsg_eident: .ascii "basilisk-seed: error: unknown identifier in expression\n"
.set Lmsg_eident_len, . - Lmsg_eident
Lmsg_eext:   .ascii "basilisk-seed: error: unknown extern (syscalls/load8/store8, or extern \"C\")\n"
.set Lmsg_eext_len, . - Lmsg_eext
Lmsg_estr:   .ascii "basilisk-seed: error: bad string literal (escapes: \\n \\t \\\" \\\\; no raw control chars)\n"
.set Lmsg_estr_len, . - Lmsg_estr
Lmsg_edup:   .ascii "basilisk-seed: error: duplicate static definition\n"
.set Lmsg_edup_len, . - Lmsg_edup
Lmsg_eobuf:  .ascii "basilisk-seed: error: output buffer overflow\n"
.set Lmsg_eobuf_len, . - Lmsg_eobuf
Lmsg_eint:   .ascii "basilisk-seed: internal error: bad AST\n"
.set Lmsg_eint_len, . - Lmsg_eint
