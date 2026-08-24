#!/bin/bash
# 仅编译，用于本地试运行：./ScrollReverser
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o ScrollReverser main.swift
echo "构建完成：$(pwd)/ScrollReverser"
echo "试运行（需要辅助功能权限）：./ScrollReverser"
