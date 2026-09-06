#!/usr/bin/env python3
"""Sensitive-information scan for tracked files.

检查（与 CONTRIBUTING.md「隐私」一致）：任何 git 跟踪的文件不得包含
真实的微信读书凭据——API key（wrk-…）、Cookie 值（wr_skey/wr_rt/wr_vid/
ptcz）、反滥用头（x-wrpa-*）、thirdwx 会话标识。测试夹具一律使用
`XXX` 或明显假的占位值，扫描器会放行形如 `wr_skey=XXX` 的写法。

用法：python3 tools/check_secrets.py
"""

import re
import subprocess
import sys
from pathlib import Path

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


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "-z"],
        capture_output=True,
        check=True,
    ).stdout
    return [name for name in out.decode("utf-8", "replace").split("\0") if name]


def main() -> int:
    failures = []
    scanned = 0
    for name in tracked_files():
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
