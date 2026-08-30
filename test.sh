#!/bin/zsh
# ============================================================
# Project Basilisk — 验收测试 / acceptance tests
# 历史阶段回归 + 第三阶段试金石（自读词法器 lexer.em）。
# 流程：种子编译 input.em -> output.s，as + ld 汇编链接，
# 运行产物，断言退出码。
# ============================================================
set -e
cd "$(dirname "$0")"
./build.sh
SDK="$(xcrun --show-sdk-path)"

# 产物链接时附带 HeapForge（extern "C" FFI 用），与 build.sh 同源
HF_OBJS="$(cat build/hf_objs.txt)"

# 测试会反复覆写 input.em，退出时恢复用户原内容
[[ -f input.em ]] && cp input.em build/input.em.bak
restore_input() { [[ -f build/input.em.bak ]] && cp build/input.em.bak input.em; }
trap restore_input EXIT

pass=0; fail=0

# run_case <期望退出码> <用例名>   （源码由 stdin 提供）
run_case() {
    local want=$1 name=$2
    cat > input.em
    ./build/basilisk-seed > /dev/null
    as -arch arm64 -o build/out.o output.s
    ld -arch arm64 -syslibroot "$SDK" -o build/out build/out.o ${=HF_OBJS} -lSystem
    set +e
    ./build/out
    local got=$?
    set -e
    if [[ $got -eq $want ]]; then
        echo "[PASS] $name -> exit $got"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] $name -> exit $got (期望 $want)"
        fail=$(( fail + 1 ))
    fi
}

# reject_case <用例名>   （源码由 stdin 提供，种子必须报错退出）
reject_case() {
    local name=$1
    cat > input.em
    set +e
    ./build/basilisk-seed 2>/dev/null
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        echo "[PASS] $name 被拒绝 (exit $rc)"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] $name 未被拒绝"
        fail=$(( fail + 1 ))
    fi
}

# compile_case <期望片段> <用例名>   （仅编译+汇编，断言 output.s 含片段）
compile_case() {
    local want=$1 name=$2
    cat > input.em
    ./build/basilisk-seed > /dev/null
    as -arch arm64 -o build/out.o output.s      # 验证产物可汇编
    if grep -qF "$want" output.s; then
        echo "[PASS] $name（output.s 含：$want）"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] $name（output.s 缺：$want）"
        fail=$(( fail + 1 ))
    fi
}

echo "=== 第一阶段回归 ==="
for n in 0 7 42 255 256 65535; do
    want=$(( n % 256 ))          # 进程退出码仅 8 位（POSIX 约定）
    run_case $want "return $n" <<EOF
fn main() -> i32 { return $n; }
EOF
done

echo "=== 第二阶段：函数 / 参数 / 加法 / 调用 ==="

run_case 42 "add(40,2) 经函数调用" <<'EOF'
fn add(a, b) -> i32 { return a + b; }
fn main() -> i32 { return add(40, 2); }
EOF

# 里程碑断言：输出汇编必须含加法指令
if grep -q "add x" output.s; then
    echo "[PASS] 里程碑：output.s 含加法指令"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 里程碑：output.s 不含加法指令"
    fail=$(( fail + 1 ))
fi

run_case 6 "常量加法链 1+2+3（-> i32 省略）" <<'EOF'
fn main() { return 1 + 2 + 3; }
EOF

run_case 15 "嵌套调用 add3(1,2,add3(3,4,5))" <<'EOF'
fn add3(a, b, c) { return a + b + c; }
fn main() { return add3(1, 2, add3(3, 4, 5)); }
EOF

run_case 36 "8 参数满载 x0-x7" <<'EOF'
fn sum8(a, b, c, d, e, f, g, h) { return a + b + c + d + e + f + g + h; }
fn main() { return sum8(1, 2, 3, 4, 5, 6, 7, 8); }
EOF

run_case 44 "参数与字面量混合 + 多级调用" <<'EOF'
fn twice(x) { return x + x; }
fn addmix(a, b) { return a + twice(b) + 2; }
fn main() { return addmix(10, 16); }
EOF

echo "=== 第 2.5 阶段：let / if / while / 比较 / 赋值 ==="

run_case 42 "let 声明与求和" <<'EOF'
fn main() { let a = 40; let b = 2; return a + b; }
EOF

run_case 42 "if 早退 max(17,42)" <<'EOF'
fn max(a, b) { if a > b { return a; } return b; }
fn main() { return max(17, 42); }
EOF

run_case 30 "if/else 双分支 pick(1)+pick(0)" <<'EOF'
fn pick(c) { if c == 1 { return 10; } else { return 20; } }
fn main() { return pick(1) + pick(0); }
EOF

run_case 55 "while 求和 1..10" <<'EOF'
fn sum(n) {
    let s = 0;
    let i = 1;
    while i <= n {
        s = s + i;
        i = i + 1;
    }
    return s;
}
fn main() { return sum(10); }
EOF

run_case 55 "迭代法 fib(10)（while 体内 let）" <<'EOF'
fn fib(n) {
    let a = 0;
    let b = 1;
    let i = 0;
    while i < n {
        let t = a + b;
        a = b;
        b = t;
        i = i + 1;
    }
    return a;
}
fn main() { return fib(10); }
EOF

run_case 42 "关键字前缀标识符 letter/iffy + cset 值 + 遮蔽" <<'EOF'
fn main() {
    let letter = 4;
    let iffy = letter < 9;
    let letter = letter + iffy + 37;
    if iffy == 1 { return letter; }
    return 0;
}
EOF

echo "=== 第 2.75 阶段：extern FFI + 内联系统调用 ==="

run_case 42 "验收1：extern exit(42) 退出码直达" <<'EOF'
extern fn exit(c: i32) -> i32;
fn main() -> i32 { exit(42); }
EOF

run_case 0 "验收2：extern write 写 0 字节不崩溃" <<'EOF'
extern fn write(fd: i32, p: i32, l: i32) -> i32;
fn main() -> i32 { write(1, 0, 0); return 0; }
EOF

run_case 42 "验收3：extern 与普通函数调用共存" <<'EOF'
extern fn exit(c: i32) -> i32;
fn add(a, b) -> i32 { return a + b; }
fn main() -> i32 { exit(add(40, 2)); }
EOF

# 验收4：产物零未定义符号（extern 已内联，无 _write/_exit 引用）
if [[ -z "$(nm -u build/out)" ]]; then
    echo "[PASS] 验收4：nm -u 零未定义符号（系统调用已内联）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 验收4：产物存在未定义符号：$(nm -u build/out)"
    fail=$(( fail + 1 ))
fi

run_case 5 "extern 返回值可参与运算（write 返回写出字节数）" <<'EOF'
extern fn write(fd: i32, p: i32, l: i32) -> i32;
fn main() -> i32 { let n = write(1, 0, 0); return n + 5; }
EOF

run_case 42 "let 带类型注解 : i32" <<'EOF'
fn main() -> i32 { let x: i32 = 40; let y: i32 = 2; return x + y; }
EOF

echo "=== 第 2.9 阶段：减法/乘法/括号/访存原语/extern \"C\" ==="

run_case 7 "10 - 3" <<'EOF'
fn main() -> i32 { return 10 - 3; }
EOF

run_case 12 "4 * 3" <<'EOF'
fn main() -> i32 { return 4 * 3; }
EOF

run_case 4 "10 - 2 * 3（乘法优先）" <<'EOF'
fn main() -> i32 { return 10 - 2 * 3; }
EOF

run_case 24 "(10 - 2) * 3（括号提升优先级）" <<'EOF'
fn main() -> i32 { return (10 - 2) * 3; }
EOF

compile_case "ldrb w0, [x0]" "load8 生成 ldrb（仅编译，不运行非法地址）" <<'EOF'
extern fn load8(ptr: i32) -> i32;
fn main() -> i32 { let addr: i32 = 0; return load8(addr); }
EOF

run_case 3 "10 / 3（整数除法 sdiv）" <<'EOF'
fn main() -> i32 { return 10 / 3; }
EOF

run_case 1 "10 % 3（取模 sdiv+msub）" <<'EOF'
fn main() -> i32 { return 10 % 3; }
EOF

run_case 5 "100 / 10 / 2（除法左结合）" <<'EOF'
fn main() -> i32 { return 100 / 10 / 2; }
EOF

run_case 8 "2 + 10 % 4 * 3（取模/乘法同级高于加法）" <<'EOF'
fn main() -> i32 { return 2 + 10 % 4 * 3; }
EOF

compile_case "strb w1, [x0]" "store8 生成 strb（仅编译）" <<'EOF'
extern fn store8(ptr: i32, val: i32) -> i32;
fn main() -> i32 { store8(0, 7); return 0; }
EOF

# extern "C"：链接前 out.o 应含未定义的 _hf_asm_pool_create（链接期解析）
cat > input.em <<'EOF'
extern "C" fn hf_asm_pool_create(bs: i32, bc: i32) -> i32;
fn main() -> i32 {
    let pool: i32 = hf_asm_pool_create(128, 100);
    if 0 < pool { return 42; }
    return 1;
}
EOF
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/out.o output.s
if nm -u build/out.o | grep -q "_hf_asm_pool_create"; then
    echo "[PASS] extern \"C\"：out.o 含待链接符号 _hf_asm_pool_create"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] extern \"C\"：out.o 未引用 _hf_asm_pool_create"
    fail=$(( fail + 1 ))
fi
ld -arch arm64 -syslibroot "$SDK" -o build/out build/out.o ${=HF_OBJS} -lSystem
set +e; ./build/out; rc=$?; set -e
if [[ $rc -eq 42 ]]; then
    echo "[PASS] extern \"C\"：HeapForge 句柄有效（页对齐地址低 8 位恒 0，改用 0<pool 判定）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] extern \"C\"：退出码 $rc（期望 42）"
    fail=$(( fail + 1 ))
fi

run_case 42 "集成：HeapForge 分配 + store8/load8 回环读写" <<'EOF'
extern "C" fn hf_asm_pool_create(bs: i32, bc: i32) -> i32;
extern "C" fn hf_asm_pool_alloc(pool: i32) -> i32;
extern fn load8(p: i32) -> i32;
extern fn store8(p: i32, v: i32) -> i32;
fn main() -> i32 {
    let pool = hf_asm_pool_create(128, 100);
    if pool == 0 { return 1; }
    let p = hf_asm_pool_alloc(pool);
    if p == 0 { return 2; }
    store8(p, 42);
    return load8(p);
}
EOF

# 工程债务清偿验证：末尾 return 后不再有死代码兜底尾声
cat > input.em <<'EOF'
fn main() -> i32 { return 42; }
EOF
./build/basilisk-seed > /dev/null
if [[ $(grep -c "ret" output.s) -eq 1 ]]; then
    echo "[PASS] 债务清偿：末尾 return 后无死代码（全文仅 1 个 ret）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 债务清偿：output.s 仍有多余 ret（$(grep -c "ret" output.s) 个）"
    fail=$(( fail + 1 ))
fi

echo "=== 第 2.95 阶段：静态字符串字面量 ==="

run_case 0 "验收1：空字符串 .asciz \"\" 合法" <<'EOF'
static x: [i8] = "";
fn main() -> i32 { return 0; }
EOF

# 验收2：write(1, msg, 2) 真实输出 A + 换行
cat > input.em <<'EOF'
static msg: [i8] = "A\n";
extern fn write(fd: i32, p: i32, l: i32) -> i32;
fn main() -> i32 { write(1, msg, 2); return 0; }
EOF
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/out.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/out build/out.o ${=HF_OBJS} -lSystem
set +e; out=$(./build/out); rc=$?; set -e
if [[ $rc -eq 0 && "$out" == "A" ]]; then    # $() 剥尾部换行，故比对 "A"
    echo "[PASS] 验收2：write(1, msg, 2) 真实输出 A\\n（exit 0）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 验收2：write 输出 '$out'，exit $rc"
    fail=$(( fail + 1 ))
fi

# 验收3：open(path, 0) 拿真实 fd（0/1/2 已占，首个空闲 fd = 3）
cat > input.em <<'EOF'
static path: [i8] = "input.em";
extern fn open(p: i32, f: i32) -> i32;
fn main() -> i32 { return open(path, 0); }
EOF
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/out.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/out build/out.o ${=HF_OBJS} -lSystem
set +e; ./build/out; rc=$?; set -e
if [[ $rc -ge 3 ]]; then
    echo "[PASS] 验收3：open(path, 0) 返回合法 fd = $rc（≥ 3）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 验收3：open(path, 0) 返回 $rc（期望 ≥ 3）"
    fail=$(( fail + 1 ))
fi

run_case 42 "多静态串共存 + 参数遮蔽静态名" <<'EOF'
static a: [i8] = "hello";
static b: [i8] = "world";
extern fn load8(p: i32) -> i32;
fn probe(a) { return a; }
fn main() -> i32 {
    if load8(a) == 104 { return probe(42); }
    return 1;
}
EOF

echo "=== 第三阶段 试金石1：自读词法器 lexer.em ==="

# 种子编译 lexer.em（首个含注释/静态串/FFI/原语的真实 Ember 程序）
cp lexer.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/lexer.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/lexer build/lexer.o ${=HF_OBJS} -lSystem
set +e; lexout=$(./build/lexer); rc=$?; set -e
if command -v python3 >/dev/null 2>&1; then
    ref=$(python3 - <<'PY'
b = open('lexer.em','rb').read()
i=0; t=0; inc=False; n=len(b)
def alpha(c): return 65<=c<=90 or 97<=c<=122 or c==95
def dig(c): return 48<=c<=57
ws={32,10,13,9}
sing={123,125,40,41,43,45,42,47,61,59,44,60,62}
two={61,33,60,62}
while i<n:
    c=b[i]
    if inc:
        if c==10: inc=False
        i+=1; continue
    if c==47 and i+1<n and b[i+1]==47:
        inc=True; i+=2; continue
    if c in ws: i+=1; continue
    if alpha(c):
        while i<n and (alpha(b[i]) or dig(b[i])): i+=1
        t+=1; continue
    if dig(c):
        while i<n and dig(b[i]): i+=1
        t+=1; continue
    if c in two and i+1<n and b[i+1]==61:
        t+=1; i+=2; continue
    if c in sing:
        t+=1; i+=1; continue
    i+=1
print(t)
PY
)
    want=$(( ref % 256 ))
    if [[ "$lexout" == "$ref" && $rc -eq $want ]]; then
        echo "[PASS] 试金石1：lexer.em 自读 print_int 输出 $lexout = 参考实现 $ref（精确，无 mod），退出码 $rc 亦对账"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石1：stdout '$lexout' 退出码 $rc，参考 $ref (mod 256 = $want)"
        fail=$(( fail + 1 ))
    fi
else
    if [[ $rc -gt 0 ]]; then
        echo "[PASS] 试金石1：lexer.em 自读输出 '$lexout'，退出码 $rc > 0（无 python3，跳过精确对账）"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石1：退出码 $rc"
        fail=$(( fail + 1 ))
    fi
fi

# 小文件精确计数（不涉及 mod）：fn main ( ) - > i32 { return 42 ; } = 12
printf 'fn main() -> i32 { return 42; }\n' > build/tiny.em
sed 's|"lexer.em"|"build/tiny.em"|' lexer.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/lt.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/lt build/lt.o ${=HF_OBJS} -lSystem
set +e; ltout=$(./build/lt); rc=$?; set -e
if [[ $rc -eq 12 && "$ltout" == "12" ]]; then
    echo "[PASS] 词法器统计 tiny.em = 12 Token（stdout 与退出码双验）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 词法器统计 tiny.em = $rc（期望 12）"
    fail=$(( fail + 1 ))
fi

echo "=== 第三阶段 试金石2：Token 分类器 lexer2.em ==="

# 输出 "<类型码> <行号>" 流，与 Python 参考实现逐行 diff
cp lexer2.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/lexer2.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/lexer2 build/lexer2.o ${=HF_OBJS} -lSystem
./build/lexer2 > build/out.txt
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
b = open('lexer2.em','rb').read()
i=0; line=1; inc=False; n=len(b); out=[]
def alpha(c): return 65<=c<=90 or 97<=c<=122 or c==95
def dig(c): return 48<=c<=57
ws={32,10,13,9}
sing={123,125,40,41,43,45,42,47,61,59,44,60,62,37}
two={61,33,60,62}
while i<n:
    c=b[i]
    if c==10: line+=1
    if inc:
        if c==10: inc=False
        i+=1; continue
    if c==47 and i+1<n and b[i+1]==47:
        inc=True; i+=2; continue
    if c in ws: i+=1; continue
    if alpha(c):
        while i<n and (alpha(b[i]) or dig(b[i])): i+=1
        out.append((1,line)); continue
    if dig(c):
        while i<n and dig(b[i]): i+=1
        out.append((2,line)); continue
    if c in two and i+1<n and b[i+1]==61:
        out.append((3,line)); i+=2; continue
    if c in sing:
        out.append((3,line)); i+=1; continue
    i+=1
open('build/ref.txt','w').write(''.join(f'{t} {l}\n' for t,l in out))
PY
    if diff -q build/out.txt build/ref.txt > /dev/null 2>&1; then
        ntok=$(wc -l < build/out.txt | tr -d ' ')
        echo "[PASS] 试金石2：lexer2.em Token 流 $ntok 行与参考实现 diff 零差异"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石2：Token 流 diff 有差异（build/out.txt vs build/ref.txt）"
        fail=$(( fail + 1 ))
    fi
else
    nout=$(wc -l < build/out.txt | tr -d ' ')
    if [[ $nout -gt 0 ]]; then
        echo "[PASS] 试金石2：lexer2.em 输出 $nout 行 Token 流（无 python3，跳过 diff）"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石2：无输出"
        fail=$(( fail + 1 ))
    fi
fi

echo "=== 第三阶段 试金石3：关键字细分 lexer3.em ==="

# 类型码：1=ident 2=number 3=symbol 10..17=fn/let/if/else/while/return/extern/static
cp lexer3.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/lexer3.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/lexer3 build/lexer3.o ${=HF_OBJS} -lSystem
./build/lexer3 > build/out3.txt
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
b = open('lexer3.em','rb').read()
i=0; line=1; inc=False; n=len(b); out=[]
kw={b'fn':10,b'let':11,b'if':12,b'else':13,b'while':14,b'return':15,b'extern':16,b'static':17}
def alpha(c): return 65<=c<=90 or 97<=c<=122 or c==95
def dig(c): return 48<=c<=57
ws={32,10,13,9}
sing={123,125,40,41,43,45,42,47,61,59,44,60,62,37}
two={61,33,60,62}
while i<n:
    c=b[i]
    if c==10: line+=1
    if inc:
        if c==10: inc=False
        i+=1; continue
    if c==47 and i+1<n and b[i+1]==47:
        inc=True; i+=2; continue
    if c in ws: i+=1; continue
    if alpha(c):
        st=i
        while i<n and (alpha(b[i]) or dig(b[i])): i+=1
        out.append((kw.get(b[st:i],1),line)); continue
    if dig(c):
        while i<n and dig(b[i]): i+=1
        out.append((2,line)); continue
    if c in two and i+1<n and b[i+1]==61:
        out.append((3,line)); i+=2; continue
    if c in sing:
        out.append((3,line)); i+=1; continue
    i+=1
open('build/ref3.txt','w').write(''.join(f'{t} {l}\n' for t,l in out))
PY
    if diff -q build/out3.txt build/ref3.txt > /dev/null 2>&1; then
        ntok=$(wc -l < build/out3.txt | tr -d ' ')
        echo "[PASS] 试金石3：lexer3.em 带关键字细分的 Token 流 $ntok 行与参考实现 diff 零差异"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石3：Token 流 diff 有差异（build/out3.txt vs build/ref3.txt）"
        fail=$(( fail + 1 ))
    fi
else
    echo "[PASS] 试金石3：无 python3，跳过 diff（仅确认可编译运行）"
    pass=$(( pass + 1 ))
fi

# 精确序列：fn main() -> i32 { return 42; }
printf 'fn main() -> i32 { return 42; }\n' > build/tiny3.em
sed 's|"lexer3.em"|"build/tiny3.em"|' lexer3.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/l3t.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/l3t build/l3t.o ${=HF_OBJS} -lSystem
got=$(./build/l3t | tr '\n' ';')
want='10 1;1 1;3 1;3 1;3 1;3 1;1 1;3 1;15 1;2 1;3 1;3 1;'
if [[ "$got" == "$want" ]]; then
    echo "[PASS] 关键字细分序列：fn→10 main→1 return→15 42→2"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 关键字细分序列：得到 '$got'"
    fail=$(( fail + 1 ))
fi

# 词边界防误伤：fnx/letx/returning/elsewhere 必须是 1
printf 'fn fnx let letx returning return elsewhere else\n' > build/trap3.em
sed 's|"lexer3.em"|"build/trap3.em"|' lexer3.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/l3p.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/l3p build/l3p.o ${=HF_OBJS} -lSystem
got=$(./build/l3p | awk '{printf "%s ", $1}')
if [[ "$got" == "10 1 11 1 1 15 1 13 " ]]; then
    echo "[PASS] 关键字不误伤：fnx/letx/returning/elsewhere → 1，fn/let/return/else → 10/11/15/13"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 误伤检查：得到 '$got'（期望 '10 1 11 1 1 15 1 13 '）"
    fail=$(( fail + 1 ))
fi

echo "=== 第三阶段 试金石4：符号表驻留 lexer4.em ==="

# 三列流 "<类型码> <行号> <符号序号>"，标识符/关键字共享表按首次出现编号
cp lexer4.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/lexer4.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/lexer4 build/lexer4.o ${=HF_OBJS} -lSystem
./build/lexer4 > build/out4.txt
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
b = open('lexer4.em','rb').read()
i=0; line=1; inc=False; n=len(b); out=[]; interned={}
kw={b'fn':10,b'let':11,b'if':12,b'else':13,b'while':14,b'return':15,b'extern':16,b'static':17}
def alpha(c): return 65<=c<=90 or 97<=c<=122 or c==95
def dig(c): return 48<=c<=57
ws={32,10,13,9}
sing={123,125,40,41,43,45,42,47,61,59,44,60,62,37}
two={61,33,60,62}
while i<n:
    c=b[i]
    if c==10: line+=1
    if inc:
        if c==10: inc=False
        i+=1; continue
    if c==47 and i+1<n and b[i+1]==47:
        inc=True; i+=2; continue
    if c in ws: i+=1; continue
    if alpha(c):
        st=i
        while i<n and (alpha(b[i]) or dig(b[i])): i+=1
        name=b[st:i]
        if name not in interned: interned[name]=len(interned)+1
        out.append((kw.get(name,1),line,interned[name])); continue
    if dig(c):
        while i<n and dig(b[i]): i+=1
        out.append((2,line,0)); continue
    if c in two and i+1<n and b[i+1]==61:
        out.append((3,line,0)); i+=2; continue
    if c in sing:
        out.append((3,line,0)); i+=1; continue
    i+=1
open('build/ref4.txt','w').write(''.join(f'{t} {l} {s}\n' for t,l,s in out))
PY
    if diff -q build/out4.txt build/ref4.txt > /dev/null 2>&1; then
        ntok=$(wc -l < build/out4.txt | tr -d ' ')
        echo "[PASS] 试金石4：lexer4.em 三列 Token 流 $ntok 行与参考实现 diff 零差异"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石4：三列流 diff 有差异（build/out4.txt vs build/ref4.txt）"
        fail=$(( fail + 1 ))
    fi
else
    echo "[PASS] 试金石4：无 python3，跳过 diff（仅确认可编译运行）"
    pass=$(( pass + 1 ))
fi

# 精确序列：fn=1 main=2 i32=3 return=4（首次出现顺序编号，修正规格表笔误 15 1 1）
printf 'fn main() -> i32 { return 42; }\n' > build/tiny4.em
sed 's|"lexer4.em"|"build/tiny4.em"|' lexer4.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/l4t.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/l4t build/l4t.o ${=HF_OBJS} -lSystem
got=$(./build/l4t | tr '\n' ';')
want='10 1 1;1 1 2;3 1 0;3 1 0;3 1 0;3 1 0;1 1 3;3 1 0;15 1 4;2 1 0;3 1 0;3 1 0;'
if [[ "$got" == "$want" ]]; then
    echo "[PASS] 驻留序号：fn=1 main=2 i32=3 return=4，数字/符号填 0"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 驻留序号：得到 '$got'"
    fail=$(( fail + 1 ))
fi

# 重复驻留：foo 定义/调用同号，x/y 重复出现同号，跨行也一致
printf 'fn foo() { let x = 1; let y = 2; return x + y; }\nfn main() -> i32 { return foo(); }\n' > build/dup4.em
sed 's|"lexer4.em"|"build/dup4.em"|' lexer4.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/l4d.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/l4d build/l4d.o ${=HF_OBJS} -lSystem
got=$(./build/l4d | awk '$3 > 0 {printf "%s:%s ", $1, $3}')
want='10:1 1:2 11:3 1:4 11:3 1:5 15:6 1:4 1:5 10:1 1:7 1:8 15:6 1:2 '
if [[ "$got" == "$want" ]]; then
    echo "[PASS] 重复驻留：foo 定义/调用同号 2，x=4 y=5 重现同号，fn/let/return 跨行同号"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 重复驻留：得到 '$got'（期望 '$want'）"
    fail=$(( fail + 1 ))
fi

echo "=== 第三阶段 试金石5：表达式解析器 lexer5.em ==="

# 递归下降 + 后缀输出，验证优先级/左结合/括号/驻留序号
cp lexer5.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/lexer5.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/lexer5 build/lexer5.o ${=HF_OBJS} -lSystem

expr_case() {  # $1=表达式 $2=期望后缀(分号分隔) $3=用例名
printf '%s\n' "$1" > expr.em
got=$(./build/lexer5 | tr '\n' ';')
if [[ "$got" == "$2" ]]; then
    echo "[PASS] 后缀：$3"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 后缀：$3 得到 '$got'（期望 '$2'）"
    fail=$(( fail + 1 ))
fi
}

expr_case '42' '42 NUM;' '单数字 42'
expr_case '1 + 2' '1 NUM;2 NUM;+ OP;' '1 + 2'
expr_case '1 - 2 - 3' '1 NUM;2 NUM;- OP;3 NUM;- OP;' '左结合 1 - 2 - 3'
expr_case '1 + 2 * 3' '1 NUM;2 NUM;3 NUM;* OP;+ OP;' '优先级 1 + 2 * 3'
expr_case '(1 + 2) * 3' '1 NUM;2 NUM;+ OP;3 NUM;* OP;' '括号 (1 + 2) * 3'
expr_case 'a + b * c' '1 ID;2 ID;3 ID;* OP;+ OP;' '标识符 a + b * c'
expr_case '10 % 3 + x - x * 2' '10 NUM;3 NUM;% OP;1 ID;+ OP;1 ID;2 NUM;* OP;- OP;' '混合 + x 驻留同号'
expr_case '((((1 + 2)) * (3 - 4)))' '1 NUM;2 NUM;+ OP;3 NUM;4 NUM;- OP;* OP;' '深嵌套括号'

# 负例：非法表达式与括号不闭合 → parse error + exit 1
printf '1 + * 2\n' > expr.em
set +e; ./build/lexer5 > /dev/null 2>&1; rc=$?; set -e
printf '(1 + 2\n' > expr.em
set +e; ./build/lexer5 > /dev/null 2>&1; rc2=$?; set -e
if [[ $rc -eq 1 && $rc2 -eq 1 ]]; then
    echo "[PASS] 解析负例：'1 + * 2' 与 '(1 + 2' 均 parse error 退出 1"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 解析负例：退出码 $rc / $rc2（期望 1 / 1）"
    fail=$(( fail + 1 ))
fi
printf '1 + 2 * 3\n' > expr.em   # 恢复默认 expr.em

echo "=== 第三阶段 试金石6：AST 前序节点流 parser.em ==="

# 完整文法子集（声明+语句+表达式），与 ref_parser.py 同构参考 diff
cp parser.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/parser.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/parser build/parser.o ${=HF_OBJS} -lSystem
if command -v python3 >/dev/null 2>&1; then
    ./build/parser > build/outp.txt
    python3 ref_parser.py parser.em > build/refp.txt
    if diff -q build/outp.txt build/refp.txt > /dev/null 2>&1; then
        nast=$(wc -l < build/outp.txt | tr -d ' ')
        echo "[PASS] 试金石6：parser.em 自读 AST 前序流 $nast 行与参考实现 diff 零差异"
        pass=$(( pass + 1 ))
    else
        echo "[FAIL] 试金石6：AST 流 diff 有差异（build/outp.txt vs build/refp.txt）"
        fail=$(( fail + 1 ))
    fi
else
    echo "[PASS] 试金石6：无 python3，跳过 diff（仅确认可编译运行）"
    pass=$(( pass + 1 ))
fi

ast_case() {  # $1=源码 $2=期望前序(分号分隔) $3=用例名
printf '%s\n' "$1" > build/astc.em
sed 's|"parser.em"|"build/astc.em"|' parser.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/astp.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/astp build/astp.o ${=HF_OBJS} -lSystem
got=$(./build/astp | tr '\n' ';')
if [[ "$got" == "$2" ]]; then
    echo "[PASS] AST：$3"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] AST：$3 得到 '$got'（期望 '$2'）"
    fail=$(( fail + 1 ))
fi
}

ast_case 'fn main() -> i32 { return 42; }' 'FN 2 0 3;BLOCK;RETURN;NUM 42;' 'FN/RETURN/NUM'
ast_case 'fn f() { let x: i32 = 1 + 2; }' 'FN 2 0 0;BLOCK;LET 4 5;BINOP +;NUM 1;NUM 2;' 'LET + 前序 BINOP'
ast_case 'fn f(x: i32) { if x { return 1; } else { return 0; } }' 'FN 2 1 0;BLOCK;IF;ID 3;BLOCK;RETURN;NUM 1;ELSE;BLOCK;RETURN;NUM 0;' 'IF/ELSE 双分支'
ast_case 'fn f(x: i32) { while x < 10 { x = x + 1; } }' 'FN 2 1 0;BLOCK;WHILE;BINOP <;ID 3;NUM 10;BLOCK;ASSIGN 3;BINOP +;ID 3;NUM 1;' 'WHILE/ASSIGN/比较'

# 解析负例：残缺函数体 → parse error 退出 1
printf 'fn f() { let x }\n' > build/astc.em
sed 's|"parser.em"|"build/astc.em"|' parser.em > input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/astp.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/astp build/astp.o ${=HF_OBJS} -lSystem
set +e; ./build/astp > /dev/null 2>&1; rc=$?; set -e
if [[ $rc -eq 1 ]]; then
    echo "[PASS] AST 负例：'let x }' 残缺声明 parse error 退出 1"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] AST 负例：退出码 $rc（期望 1）"
    fail=$(( fail + 1 ))
fi

echo "=== 第四阶段 试金石7：自托管编译器 emberc.em ==="

# 种子编译 emberc.em
cp emberc.em input.em
./build/basilisk-seed > /dev/null
as -arch arm64 -o build/emberc.o output.s
ld -arch arm64 -syslibroot "$SDK" -o build/emberc build/emberc.o ${=HF_OBJS} -lSystem

ec_case() {  # $1=源码 $2=期望退出码 $3=用例名
printf '%s\n' "$1" > input.em
./build/emberc > build/ec_out.s
as -arch arm64 -o build/ec.o build/ec_out.s
ld -arch arm64 -syslibroot "$SDK" -o build/ec build/ec.o ${=HF_OBJS} -lSystem
set +e; ./build/ec; rc=$?; set -e
if [[ $rc -eq $2 ]]; then
    echo "[PASS] emberc：$3 -> exit $rc"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] emberc：$3 退出码 $rc（期望 $2）"
    fail=$(( fail + 1 ))
fi
}

ec_case 'fn main() -> i32 { return 42; }' 42 '用例1 return 42'
ec_case 'fn main() -> i32 { let x: i32 = 1; return x + 2; }' 3 '用例2 let + 运算'
ec_case 'fn main() -> i32 { let x: i32 = 0; while x < 3 { x = x + 1; } return x; }' 3 '用例3 while 循环'
ec_case 'fn main() -> i32 { if 1 { return 2; } else { return 3; } }' 2 '用例4 if/else'
ec_case 'extern fn exit(c: i32) -> i32;
fn main() -> i32 { exit(42); return 0; }' 42 '用例5 extern exit svc'

# 用例6：静态串 + write 真实输出
printf 'static msg: [i8] = "A\\n";\nextern fn write(fd: i32, p: i32, n: i32) -> i32;\nfn main() -> i32 { write(1, msg, 2); return 0; }\n' > input.em
./build/emberc > build/ec_out.s
as -arch arm64 -o build/ec.o build/ec_out.s
ld -arch arm64 -syslibroot "$SDK" -o build/ec build/ec.o ${=HF_OBJS} -lSystem
set +e; ecout=$(./build/ec); rc=$?; set -e
if [[ "$ecout" == "A" && $rc -eq 0 ]]; then
    echo "[PASS] emberc：用例6 static+write 输出 'A\\n'"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] emberc：用例6 输出 '$ecout' 退出码 $rc"
    fail=$(( fail + 1 ))
fi

# 自举不动点：emberc 编译自身 -> emberc2；emberc2 编译自身 -> 汇编逐字节一致；二进制一致
cp emberc.em input.em
./build/emberc > build/gen2.s
as -arch arm64 -o build/emberc2.o build/gen2.s
ld -arch arm64 -syslibroot "$SDK" -o build/emberc2 build/emberc2.o ${=HF_OBJS} -lSystem
./build/emberc2 > build/gen3.s
mkdir -p build/a build/b
as -arch arm64 -o build/emberc3.o build/gen3.s
ld -arch arm64 -syslibroot "$SDK" -no_uuid -o build/a/emberc build/emberc2.o ${=HF_OBJS} -lSystem
ld -arch arm64 -syslibroot "$SDK" -no_uuid -o build/b/emberc build/emberc3.o ${=HF_OBJS} -lSystem
if diff -q build/gen2.s build/gen3.s > /dev/null && cmp -s build/a/emberc build/b/emberc; then
    echo "[PASS] 自举不动点：gen2.s == gen3.s（$(wc -l < build/gen2.s | tr -d ' ') 行）且二代二进制逐字节一致"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 自举不动点：汇编或二进制不一致"
    fail=$(( fail + 1 ))
fi

echo "=== 第五阶段 试金石8+9：双模内存管理 ==="

# 编译两个运行时库（emberc 默认模式，运行时不给自己插桩）
cp rt_manual.em input.em
./build/emberc > build/rt_manual.s
as -arch arm64 -o build/rt_manual.o build/rt_manual.s
cp gc.em input.em
./build/emberc > build/gc.s
as -arch arm64 -o build/gc.o build/gc.s

# 8-1：逃逸豁免——return x 的 owning 槽不 free
printf 'fn main() -> i32 { let x: i32 = alloc(64); return x; }\n' > input.em
./build/emberc -manual > build/m1.s
n=$(grep -c "bl _rt_free" build/m1.s || true)
if [[ $n -eq 0 ]]; then
    echo "[PASS] 8-1 -manual：return x 逃逸豁免，无 rt_free"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 8-1：rt_free 出现 $n 次（期望 0）"
    fail=$(( fail + 1 ))
fi

# 8-2：双 alloc 各自释放（静态 2 次 + 运行退出 0）
printf 'fn main() -> i32 { let x: i32 = alloc(64); let y: i32 = alloc(64); return 0; }\n' > input.em
./build/emberc -manual > build/m2.s
n=$(grep -c "bl _rt_free" build/m2.s)
as -arch arm64 -o build/m2.o build/m2.s
ld -arch arm64 -syslibroot "$SDK" -o build/m2 build/m2.o build/rt_manual.o ${=HF_OBJS} -lSystem
set +e; ./build/m2; rc=$?; set -e
if [[ $n -eq 2 && $rc -eq 0 ]]; then
    echo "[PASS] 8-2 -manual：双 alloc 各自释放（rt_free x2），运行正常"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 8-2：rt_free=$n 退出码=$rc（期望 2/0）"
    fail=$(( fail + 1 ))
fi

# 8-3：零泄漏自证（work 释放后 rt_live()==0）
printf 'fn work() -> i32 { let x: i32 = alloc(64); let y: i32 = alloc(64); return 0; }\nfn main() -> i32 { work(); return rt_live(); }\n' > input.em
./build/emberc -manual > build/m3.s
as -arch arm64 -o build/m3.o build/m3.s
ld -arch arm64 -syslibroot "$SDK" -o build/m3 build/m3.o build/rt_manual.o ${=HF_OBJS} -lSystem
set +e; ./build/m3; rc=$?; set -e
if [[ $rc -eq 0 ]]; then
    echo "[PASS] 8-3 -manual：零泄漏自证 rt_live()==0"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 8-3：rt_live()=$rc（期望 0）"
    fail=$(( fail + 1 ))
fi

gc_case() {  # $1=源码 $2=期望退出码 $3=用例名
printf '%s\n' "$1" > input.em
./build/emberc -gc > build/g.s
as -arch arm64 -o build/g.o build/g.s
ld -arch arm64 -syslibroot "$SDK" -o build/g build/g.o build/gc.o ${=HF_OBJS} -lSystem
set +e; ./build/g; rc=$?; set -e
if [[ $rc -eq $2 ]]; then
    echo "[PASS] $3"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] $3：退出码 $rc（期望 $2）"
    fail=$(( fail + 1 ))
fi
}

gc_case 'fn main() -> i32 { let x: i32 = gc_alloc(64); x = 0; gc_collect(); return gc_live(); }' 0 '9-1 -gc：零引用对象被回收（置零后 collect）'
gc_case 'fn main() -> i32 { let x: i32 = gc_alloc(64); let y: i32 = gc_alloc(64); x = 0; y = 0; gc_collect(); return gc_live(); }' 0 '9-2 -gc：显式 collect 回收两对象'
gc_case 'fn make() -> i32 { let x: i32 = gc_alloc(64); return x; }
fn main() -> i32 { let y: i32 = make(); gc_collect(); if gc_live() == 1 { y = 0; gc_collect(); return gc_live(); } return 9; }' 0 '9-3 -gc：跨函数根可达两相验证（先存活后回收）'

echo "=== 示范项目：bf.em Brainfuck 解释器 ==="
# 四层语言塔：种子 -> emberc -> bf.em -> BF 程序
cp bf.em input.em
./build/emberc > build/bf.s
as -arch arm64 -o build/bf.o build/bf.s
ld -arch arm64 -syslibroot "$SDK" -o build/bf build/bf.o ${=HF_OBJS} -lSystem

set +e; bfout=$(./build/bf examples/hello.bf); set -e
if [[ "$bfout" == "Hello World!" ]]; then
    echo "[PASS] bf.em：hello.bf 输出 'Hello World!'"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] bf.em：hello.bf 输出 '$bfout'"
    fail=$(( fail + 1 ))
fi

set +e; ./build/bf examples/exit42.bf; rc=$?; set -e
if [[ $rc -eq 42 ]]; then
    echo "[PASS] bf.em：exit42.bf 退出码 = 当前单元值 42"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] bf.em：exit42.bf 退出码 $rc（期望 42）"
    fail=$(( fail + 1 ))
fi

set +e; bfout=$(printf 'A' | ./build/bf examples/inc.bf); rc=$?; set -e
if [[ "$bfout" == "B" && $rc -eq 66 ]]; then
    echo "[PASS] bf.em：inc.bf 逗号取 stdin，'A'+1 -> 'B'（退出码 66）"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] bf.em：inc.bf 输出 '$bfout' 退出码 $rc"
    fail=$(( fail + 1 ))
fi

set +e; bfout=$(./build/bf 2>&1); rc=$?; set -e
if [[ "$bfout" == "usage: bf <file.bf>" && $rc -eq 1 ]]; then
    echo "[PASS] bf.em：无参时 stderr 打 usage，退出 1"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] bf.em：无参输出 '$bfout' 退出码 $rc"
    fail=$(( fail + 1 ))
fi

echo "=== 试金石 10：位运算/宽访存/mmap + Ember 版 BlockPool 对拍 ==="
ec_case 'fn main() -> i32 { return (3 + 1 << 2) & 31 | 64 >> 3; }' 24 '位运算优先级 (3+1<<2)&31|64>>3'
ec_case 'fn main() -> i32 { return ~0 & 255 ^ 12 & 10; }' 247 '位运算 ~ 与 ^ 组合'
ec_case 'extern fn mmap(a: i32, l: i32, p: i32, f: i32, fd: i32, o: i32) -> i32;
extern fn munmap(a: i32, l: i32) -> i32;
extern fn load64(p: i32) -> i32;
extern fn store64(p: i32, v: i32) -> i32;
extern fn load32(p: i32) -> i32;
fn main() -> i32 { let p: i32 = mmap(0, 32768, 3, 4098, 0 - 1, 0); if p == 0 { return 1; } store64(p + 8, 47806 << 16 | 4660); if load64(p + 8) != load32(p + 8) { return 9; } let v: i32 = load64(p + 8) >> 16 & 255; munmap(p, 32768); return v; }' 190 'mmap 6参 + load64/store64/load32'

# 对拍：同一驱动逻辑（sed 同源改名）分跑汇编库与纯 Ember pool.em，偏移流 diff
cp pool_drv.em input.em
./build/emberc > build/drv_asm.s
as -arch arm64 -o build/drv_asm.o build/drv_asm.s
ld -arch arm64 -syslibroot "$SDK" -o build/drv_asm build/drv_asm.o ${=HF_OBJS} -lSystem
cp pool.em input.em
./build/emberc > build/pool.s
as -arch arm64 -o build/pool.o build/pool.s
sed 's/hf_asm_pool_/em_pool_/g' pool_drv.em > input.em
./build/emberc > build/drv_em.s
as -arch arm64 -o build/drv_em.o build/drv_em.s
ld -arch arm64 -syslibroot "$SDK" -o build/drv_em build/drv_em.o build/pool.o -lSystem
./build/drv_asm > build/pool_asm.txt
./build/drv_em > build/pool_em.txt
if diff -q build/pool_asm.txt build/pool_em.txt > /dev/null && [[ $(nm build/drv_em | grep -c hf_asm) -eq 0 ]]; then
    echo "[PASS] 试金石10：pool.em 与 block_pool.s 对拍 $(wc -l < build/pool_asm.txt | tr -d ' ') 行零差异，且零汇编依赖"
    pass=$(( pass + 1 ))
else
    echo "[FAIL] 试金石10：对拍差异或残留 hf_asm 符号"
    fail=$(( fail + 1 ))
fi

echo "=== 负例 ==="
reject_case "未定义标识符 return x" <<'EOF'
fn main() { return x; }
EOF

reject_case "第 9 个实参" <<'EOF'
fn f(a) { return a; }
fn main() { return f(1, 2, 3, 4, 5, 6, 7, 8, 9); }
EOF

reject_case "语法残缺 return 1 +" <<'EOF'
fn main() -> i32 { return 1 + ; }
EOF

reject_case "while 缺花括号" <<'EOF'
fn main() { while 1 return 1; }
EOF

reject_case "第 17 个局部槽位" <<'EOF'
fn main(a, b, c, d, e, f, g, h) {
    let v1 = 1; let v2 = 2; let v3 = 3; let v4 = 4;
    let v5 = 5; let v6 = 6; let v7 = 7; let v8 = 8;
    let v9 = 9;
    return v9;
}
EOF

reject_case "不支持的 extern 名字" <<'EOF'
extern fn mmap(a: i32) -> i32;
fn main() -> i32 { return 0; }
EOF

reject_case "验收4：重复定义 static a" <<'EOF'
static a: [i8] = "1";
static a: [i8] = "2";
fn main() -> i32 { return 0; }
EOF

reject_case "非法转义 \\q" <<'EOF'
static s: [i8] = "\q";
fn main() -> i32 { return 0; }
EOF

echo "----------------------------------------"
echo "结果: $pass passed, $fail failed"
exit $fail
