#!/usr/bin/env python3
# ref_parser.py - parser.em 的同构参考实现（试金石 6 验收基准）
# 用法: python3 ref_parser.py <源文件>
# 输出与 parser.em 完全一致的前序节点流；实现策略逐条对应（intern 含关键字、
# 字符串转义两字节跳、双字符比较、STATIC 原文输出、缺省返回类型 0）
import sys

KW = {b'fn': 10, b'let': 11, b'if': 12, b'else': 13, b'while': 14,
      b'return': 15, b'extern': 16, b'static': 17}

src = open(sys.argv[1], 'rb').read()
n = len(src)
pos = 0
interned = {}
cur = (0, 0, 0)   # (type, val, aux)

def isal(c): return 65 <= c <= 90 or 97 <= c <= 122 or c == 95
def isdg(c): return 48 <= c <= 57

def advance():
    global pos, cur
    while True:
        if pos < n and src[pos] in (32, 10, 13, 9):
            pos += 1
            continue
        if pos + 1 < n and src[pos] == 47 and src[pos + 1] == 47:
            while pos < n and src[pos] != 10:
                pos += 1
            continue
        break
    if pos >= n:
        cur = (0, 0, 0)
        return
    c = src[pos]
    if isdg(c):
        v = 0
        while pos < n and isdg(src[pos]):
            v = v * 10 + src[pos] - 48
            pos += 1
        cur = (2, v, 0)
        return
    if isal(c):
        st = pos
        while pos < n and (isal(src[pos]) or isdg(src[pos])):
            pos += 1
        name = src[st:pos]
        if name not in interned:
            interned[name] = len(interned) + 1
        cur = (KW.get(name, 1), interned[name], 0)
        return
    if c == 34:
        pos += 1
        aux = pos
        while pos < n and src[pos] != 34:
            pos += 2 if src[pos] == 92 else 1
        v = pos - aux
        pos += 1
        cur = (34, v, aux)
        return
    ty = c
    pos += 1
    if c in (61, 33, 60, 62) and pos < n and src[pos] == 61:
        ty = {61: 200, 33: 201, 60: 202, 62: 203}[c]
        pos += 1
    cur = (ty, 0, 0)

def err():
    sys.stdout.write('parse error\n')
    sys.exit(1)

def eat(t):
    if cur[0] != t:
        err()
    advance()

OPS = {200: '==', 201: '!=', 202: '<=', 203: '>='}

def emit(node):
    k = node[0]
    if k == 1:
        print(f'NUM {node[1]}')
    elif k == 2:
        print(f'ID {node[1]}')
    elif k == 3:
        print(f'BINOP {OPS.get(node[1], chr(node[1]))}')
        emit(node[2]); emit(node[3])
    elif k == 4:
        print(f'CALL {node[1]} {len(node[2])}')
        for a in node[2]:
            emit(a)

def parse_call(fid):
    advance()          # (
    args = []
    if cur[0] != 41:
        while True:
            args.append(parse_expr())
            if cur[0] == 44:
                advance()
            else:
                break
    eat(41)
    return (4, fid, args)

def parse_factor():
    t, v, _ = cur
    if t == 2:
        advance(); return (1, v)
    if t == 1:
        advance()
        if cur[0] == 40:
            return parse_call(v)
        return (2, v)
    if t == 40:
        advance()
        e = parse_expr()
        eat(41)
        return e
    err()

def parse_term():
    l = parse_factor()
    while cur[0] in (42, 47, 37):
        op = cur[0]; advance()
        l = (3, op, l, parse_factor())
    return l

def parse_add():
    l = parse_term()
    while cur[0] in (43, 45):
        op = cur[0]; advance()
        l = (3, op, l, parse_term())
    return l

def parse_expr():
    l = parse_add()
    if cur[0] in (60, 62, 200, 201, 202, 203):
        op = cur[0]; advance()
        return (3, op, l, parse_add())
    return l

def parse_block():
    eat(123)
    print('BLOCK')
    while cur[0] != 125 and cur[0] != 0:
        parse_stmt()
    eat(125)

def parse_stmt():
    t = cur[0]
    if t == 11:
        advance()
        name = cur[1]; eat(1)
        eat(58)
        tid = cur[1]; eat(1)
        eat(61)
        print(f'LET {name} {tid}')
        emit(parse_expr())
        eat(59)
        return
    if t == 12:
        advance()
        e = parse_expr()
        print('IF')
        emit(e)
        parse_block()
        if cur[0] == 13:
            advance()
            print('ELSE')
            parse_block()
        return
    if t == 14:
        advance()
        e = parse_expr()
        print('WHILE')
        emit(e)
        parse_block()
        return
    if t == 15:
        advance()
        print('RETURN')
        if cur[0] != 59:
            emit(parse_expr())
        eat(59)
        return
    if t == 1:
        vid = cur[1]
        advance()
        if cur[0] == 61:
            advance()
            print(f'ASSIGN {vid}')
            emit(parse_expr())
            eat(59)
            return
        if cur[0] == 40:
            print('EXPR_STMT')
            emit(parse_call(vid))
            eat(59)
            return
        err()
    if t == 123:
        parse_block()
        return
    err()

def parse_params():
    argc = 0
    if cur[0] == 1:
        while True:
            eat(1); eat(58); eat(1)
            argc += 1
            if cur[0] == 44:
                advance()
            else:
                break
    return argc

def parse_sig():
    name = cur[1]; eat(1)
    eat(40)
    argc = parse_params()
    eat(41)
    ret = 0
    if cur[0] == 45:
        advance()
        eat(62)
        ret = cur[1]
        eat(1)
    return name, argc, ret

def parse_fn():
    eat(10)
    name, argc, ret = parse_sig()
    print(f'FN {name} {argc} {ret}')
    parse_block()

def parse_extern():
    eat(16)
    if cur[0] == 34:
        advance()
    eat(10)
    name, argc, ret = parse_sig()
    print(f'EXTERN {name} {argc} {ret}')
    eat(59)

def parse_static():
    eat(17)
    name = cur[1]; eat(1)
    eat(58); eat(91); eat(1); eat(93); eat(61)
    if cur[0] != 34:
        err()
    slen, soff = cur[1], cur[2]
    body = src[soff:soff + slen].decode('latin1')
    sys.stdout.write(f'STATIC {name} {slen} {body}\n')
    advance()
    eat(59)

advance()
while cur[0] != 0:
    if cur[0] == 16:
        parse_extern()
    elif cur[0] == 17:
        parse_static()
    elif cur[0] == 10:
        parse_fn()
    else:
        err()
