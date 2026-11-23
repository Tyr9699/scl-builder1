#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验生成的 project.pbxproj：所有 24 位 ID 引用都有定义，括号平衡。"""
import os, re, sys
base = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(base, 'SCLAlertView.xcodeproj', 'project.pbxproj')
s = open(p, encoding='utf-8').read()

# 定义 = 行首 \t\t<ID> 后跟 /* */
defined = set(re.findall(r'^\t\t([0-9A-F]{24})\b', s, re.M))
# 引用 = 任意 24 位十六进制 ID
referenced = set(re.findall(r'(?<![\w])([0-9A-F]{24})(?![\w])', s))

missing = referenced - defined
# rootObject 也算引用
for m in re.findall(r'rootObject = ([0-9A-F]{24})', s):
    if m not in defined: missing.add(m)

# 括号平衡
bal = 0
for ch in s:
    if ch == '{': bal += 1
    elif ch == '}': bal -= 1
    if bal < 0: break

print(f'定义对象数: {len(defined)}')
print(f'引用对象数: {len(referenced)}')
print(f'未定义引用: {sorted(missing)}')
print(f'花括号平衡: {bal}')

ok = not missing and bal == 0
if not ok:
    sys.exit(1)
print('✅ pbxproj 结构有效')
