#!/usr/bin/env python3
"""Sensitive-information scan for git files.

检查（与 CONTRIBUTING.md「隐私」一致）：入库文件不得包含真实的微信读书
凭据——API key（wrk-…）、Cookie 值（wr_skey/wr_rt/wr_vid/ptcz）、反滥用头
（x-wrpa-*）、thirdwx 会话标识。测试夹具一律使用 `XXX` 或明显假的占位值，
扫描器会放行形如 `wr_skey=XXX` 的写法。

扫描范围：git 跟踪文件 + 未被忽略的未跟踪文件（新增文件在提交前就能扫到）。
EXEMPT_FILES 列出的文件整体豁免——目前只有扫描器自己的单测夹具
（tests/test_check_tools.py），其中刻意构造了以假乱真的凭据样例。

用法：python3 tools/check_secrets.py
"""

import re
import subprocess
import sys
from pathlib import Path

# 整体豁免的文件（相对仓库根）：内容即扫描器的测试夹具。
EXEMPT_FILES = {
    "tests/test_check_tools.py",
}

PATTERNS = [
    (
        "疑似真实 API key（wrk-…）",
        re.compile(r"wrk-(?!x{8,})[A-Za-z0-9_-]{12,}"),
    ),
    (
        "疑似真实 Cookie 值（wr_skey/wr_rt/wr_vid/ptcz）",
        # 值必须是 16 位以上的纯凭据字符，避免把 `wr_rt=Protocol.escape(x)`
        # 这类源码赋值误判成 Cookie；占位写法 `wr_skey=XXX` 放行。
        re.compile(r"\b(wr_skey|wr_rt|wr_vid|ptcz)=((?!XXX)[A-Za-z0-9_%+/-]{16,})"),
    ),
    (
        "疑似真实反滥用头（x-wrpa-*）",
        re.compile(r"x-wrpa-[0-9]+:\s*((?!\.\.\.)[A-Za-z0-9+/=_-]{12,})"),
    ),
    (
        "疑似 thirdwx 会话标识",
        re.compile(r"thirdwx[=:]\s*[A-Za-z0-9_-]{8,}"),
    ),
]

MAX_BYTES = 2_000_000


def candidate_files():
    """跟踪文件 + 未被忽略的未跟踪文件（新增文件提交前即可扫到）。"""
    out = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        check=True,
    ).stdout
    names = [name for name in out.decode("utf-8", "replace").split("\0") if name]
    return [name for name in names if name not in EXEMPT_FILES]


def main() -> int:
    failures = []
    scanned = 0
    for name in candidate_files():
        path = Path(name)
        if not path.is_file():
            continue
        data = path.read_bytes()
        if len(data) > MAX_BYTES:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        scanned += 1
        for label, pattern in PATTERNS:
            for match in pattern.finditer(text):
                line_no = text.count("\n", 0, match.start()) + 1
                snippet = match.group(0)
                if len(snippet) > 48:
                    snippet = snippet[:48] + "…"
                failures.append(f"{name}:{line_no} {label}: {snippet}")

    if failures:
        print(f"secret scan FAILED ({len(failures)} 处命中):")
        for failure in failures:
            print("  - " + failure)
        return 1

    print(f"secret scan OK ({scanned} 个跟踪文件无敏感信息命中)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
