#!/usr/bin/env python3
"""Module namespace policy check for the PickThought plugin.

规则（与 CONTRIBUTING.md「项目约定」一致）：

1. 项目自有 Lua 模块必须位于 `pickthought.koplugin/pickthought/` 下，
   并以 `require("pickthought.<module>")` 加载；想法弹窗 UI 位于
   `pickthought/thought_popup/`，同样走 `pickthought.thought_popup.*`。
2. 禁止出现项目自有的根级 `lib/`、`ui/` 目录，禁止 `require("lib.*")`
   这类裸项目命名空间。
3. KOReader 自带模块（`ui/*`、`device`、`logger`、`ffi/*`、`libs/*`、
   `util`、`socket` 等）不受限制。
4. 所有 `pickthought.*` 引用必须能解析到真实文件，防止拼写漂移。

用法：python3 tools/check_namespace.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = REPO_ROOT / "pickthought.koplugin"
NAMESPACE_DIR = "pickthought"
FORBIDDEN_ROOT_DIRS = ("lib", "ui")

# require("x") / require('x') / pcall(require, "x") / pcall(require,'x')
REQUIRE_RE = re.compile(
    r"""require\s*(?:\(\s*|\,\s*)['"]([A-Za-z0-9_.\-/]+)['"]"""
)


def module_exists(module: str) -> bool:
    if not module.startswith(NAMESPACE_DIR + "."):
        return False
    rel = module[len(NAMESPACE_DIR) + 1 :].replace(".", "/")
    base = PLUGIN_DIR / NAMESPACE_DIR
    return (base / (rel + ".lua")).is_file() or (base / rel / "init.lua").is_file()


def lua_files():
    for path in sorted(PLUGIN_DIR.rglob("*.lua")):
        yield path


def main() -> int:
    failures = []

    for dirname in FORBIDDEN_ROOT_DIRS:
        if (PLUGIN_DIR / dirname).is_dir():
            failures.append(
                f"禁止的项目根级目录存在: pickthought.koplugin/{dirname}/"
            )

    checked = 0
    for path in lua_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in REQUIRE_RE.finditer(text):
            module = match.group(1)
            checked += 1
            if module.startswith("pickthought."):
                if not module_exists(module):
                    rel = path.relative_to(REPO_ROOT)
                    failures.append(
                        f"{rel}: require(\"{module}\") 解析不到真实文件"
                    )
            elif module == "lib" or module.startswith("lib."):
                rel = path.relative_to(REPO_ROOT)
                failures.append(f"{rel}: 禁止裸项目命名空间 require(\"{module}\")")

    if failures:
        print(f"namespace check FAILED ({len(failures)} 处违规):")
        for failure in failures:
            print("  - " + failure)
        return 1

    print(f"namespace check OK ({checked} 处 require 检查通过)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
