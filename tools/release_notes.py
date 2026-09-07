#!/usr/bin/env python3
"""Generate the plain-text release notes used by Release and update.json."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import unicodedata
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Sequence, Set, Tuple


TRANSLATIONS = {
    "fix(epub): use correct addPath semantics": "修正 addPath 调用语义",
    "fix(inject): preserve thought text color": "保留想法正文颜色",
    "feat(ui): add runtime annotation style switching": "增加运行时划线样式切换",
    "fix(ui): restore thought popup key pagination": "恢复想法弹窗按键翻页",
    "fix(sync): validate spine cache files and writes": "校验正文缓存文件与写入结果",
    "合并:恢复想法弹窗按键翻页": "恢复想法弹窗按键翻页",
    "合并:运行时划线样式切换": "增加运行时划线样式切换",
}

MANUAL_REFS = {
    "合并:恢复想法弹窗按键翻页": {"issues": {16}},
    "合并:运行时划线样式切换": {"issues": {14}},
    "feat(ui): 增加运行时划线样式切换": {"issues": {14}},
    "fix(ui): 限制想法弹窗切换重绘范围": {"issues": {16}},
    "fix(thought-popup): 修复跨页裁切并完善尺寸设置": {"issues": {21}},
    "fix: 修复大文件磁盘中转误报失败": {"prs": {10}},
    "fix(epub): use correct addPath semantics": {"prs": {10}},
    "perf(epub): EPUB 大文件磁盘中转": {"prs": {10}},
    "fix(inject): preserve thought text color": {"prs": {9}},
    "fix(inject): 低内存 HTML/CSS 注入优化": {"prs": {9}},
    "perf(thoughts): SQLite 句柄 LRU 与关书释放": {"prs": {11, 18}},
    "perf(sync): 持久化正文 spine 缓存": {"prs": {12, 19}},
}

DESCRIPTION_REFS = {
    "恢复想法弹窗按键翻页": {"issues": {16}},
    "增加运行时划线样式切换": {"issues": {14}},
    "限制想法弹窗切换重绘范围": {"issues": {16}},
    "修复跨页裁切并完善尺寸设置": {"issues": {21}},
    "修复大文件磁盘中转误报失败": {"prs": {10}},
    "修正 addPath 调用语义": {"prs": {10}},
    "EPUB 大文件磁盘中转": {"prs": {10}},
    "保留想法正文颜色": {"prs": {9}},
    "低内存 HTML/CSS 注入优化": {"prs": {9}},
    "SQLite 句柄 LRU 与关书释放": {"prs": {11, 18}},
    "持久化正文 spine 缓存": {"prs": {12, 19}},
}

CATEGORIES = {
    "perf": "性能优化：",
    "feat": "新功能：",
    "fix": "问题修复：",
    "refactor": "结构调整：",
    "style": "样式优化：",
}


class ReleaseNotesError(ValueError):
    pass


def clean(text: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text)).strip()


def _normalized_mapping(mapping: Dict[str, Dict[str, Set[int]]]) -> Dict[str, Dict[str, Set[int]]]:
    return {clean(subject): refs for subject, refs in mapping.items()}


NORMALIZED_TRANSLATIONS = {clean(subject): value for subject, value in TRANSLATIONS.items()}
NORMALIZED_MANUAL_REFS = _normalized_mapping(MANUAL_REFS)
NORMALIZED_DESCRIPTION_REFS = _normalized_mapping(DESCRIPTION_REFS)


def dedupe_key(text: str) -> str:
    return re.sub(r"^(增加|新增)\s*", "", clean(text)).casefold()


def parse_subject(subject: str) -> Tuple[str | None, str | None]:
    subject = clean(subject)
    match = re.match(r"^(perf|feat|fix|refactor|style)(?:\([^)]*\))?:\s*(.*)$", subject, re.I)
    if match:
        kind = match.group(1).lower()
        description = NORMALIZED_TRANSLATIONS.get(subject, clean(match.group(2)))
        return kind, description
    if re.match(r"^合并:", subject):
        description = NORMALIZED_TRANSLATIONS.get(subject, clean(subject.split(":", 1)[1]))
        return "feat", description
    # PR 合并提交("Merge pull request #N from owner/branch"):仓库改用
    # PR 工作流后,feat/fix 提交都在分支上,主线第一父链只剩 merge 提交。
    # merge subject 本身不含标题,返回 (kind="merge", 描述=PR 号),由
    # generate_release_notes 从 pull_fetcher 取 PR 标题作为条目描述。
    match = re.match(r"^Merge pull request #(\d+)\s+from\s+\S+$", subject, re.I)
    if match:
        return "merge", f"#{match.group(1)}"
    return None, None


def _refs(subject: str, description: str) -> Tuple[Set[int], Set[int]]:
    manual = NORMALIZED_MANUAL_REFS.get(subject, {})
    described = NORMALIZED_DESCRIPTION_REFS.get(description, {})
    prs = set(manual.get("prs", set()))
    issues = set(manual.get("issues", set()))
    prs.update(described.get("prs", set()))
    issues.update(described.get("issues", set()))
    return prs, issues


def _format_reference(issues: Set[int], prs: Set[int]) -> str:
    refs: List[str] = []
    if issues:
        refs.append("Issue " + "/".join(f"#{number}" for number in sorted(issues)))
    if prs:
        refs.append("PR " + "/".join(f"#{number}" for number in sorted(prs)))
    return "（" + " / ".join(refs) + "）" if refs else ""


def generate_release_notes(
    rows: Iterable[Tuple[str, str]],
    commit_fetcher: Callable[[str], Dict[str, object]],
    pull_fetcher: Callable[[str], Sequence[Dict[str, object]]],
) -> Dict[str, object]:
    entries: Dict[str, List[str]] = {kind: [] for kind in CATEGORIES}
    seen: Set[Tuple[str, str]] = set()
    contributors: Set[str] = set()

    for sha, raw_subject in rows:
        subject = clean(raw_subject)
        kind, description = parse_subject(subject)
        if not kind or not description:
            continue
        # merge 提交:用关联 PR 的标题作为描述(kind 由 PR 标题的前缀决定,
        # 无前缀时默认 feat),refs 从 PR body 挖取,贡献者记 PR 作者。
        pr_from_merge = None
        if kind == "merge":
            discovered = list(pull_fetcher(sha))
            if not discovered:
                continue
            pr_from_merge = discovered[0]
            title = clean(str(pr_from_merge.get("title") or ""))
            kind, description = parse_subject(title)
            if not kind:
                kind, description = "feat", title
            if not description:
                continue

        if not re.search(r"[\u3400-\u9fff]", description):
            raise ReleaseNotesError(
                f"发现未翻译的发布提交，请先改为中文：{raw_subject}"
            )

        key = (kind, dedupe_key(description))
        if key in seen:
            continue
        seen.add(key)

        prs, issues = _refs(subject, description)
        manual_prs = set(prs)
        discovered_prs = [pr_from_merge] if pr_from_merge else list(pull_fetcher(sha))
        if not pr_from_merge:
            commit_data = commit_fetcher(sha)
            commit_author = (commit_data.get("author") or {}).get("login")
            if commit_author:
                contributors.add(str(commit_author))
        for pr in discovered_prs:
            number = int(pr["number"])
            if not manual_prs:
                prs.add(number)
            login = (pr.get("user") or {}).get("login")
            if login:
                contributors.add(str(login))
            body = pr.get("body") or ""
            if not manual_prs:
                for reference in re.findall(r"(?i)\bPR\s*#?(\d+)", body):
                    prs.add(int(reference))
            for reference in re.findall(
                r"(?i)\b(?:issue|issues|fixes|fixed|closes|closed|resolves|resolved)\s*#(\d+)",
                body,
            ):
                issues.add(int(reference))

        entries[kind].append(description + _format_reference(issues, prs))

    sections = [
        f"{CATEGORIES[kind]}\n" + "\n".join(entries[kind])
        for kind in CATEGORIES
        if entries[kind]
    ]
    notes = "\n\n".join(sections) or "版本发布"
    contributor_list = sorted(contributors)
    return {
        "notes": notes,
        "contributors": contributor_list,
        "contributors_text": "\n".join(f"- @{login}" for login in contributor_list)
        or "- 暂无可识别贡献者",
    }


def _run_text(command: Sequence[str]) -> str:
    return subprocess.check_output(command, text=True, encoding="utf-8")


def git_rows(previous: str, current: str) -> List[Tuple[str, str]]:
    commit_range = f"{previous}..{current}" if previous else current
    raw = _run_text(["git", "log", "--first-parent", "--format=%H%x09%s", commit_range])
    rows = []
    for line in raw.splitlines():
        if "\t" in line:
            rows.append(tuple(line.split("\t", 1)))
    return rows


def gh_json(repository: str, path: str) -> object:
    return json.loads(_run_text(["gh", "api", f"repos/{repository}/{path}"]))


def generate_from_repository(previous: str, current: str, repository: str) -> Dict[str, object]:
    rows = git_rows(previous, current)
    return generate_release_notes(
        rows,
        lambda sha: gh_json(repository, f"commits/{sha}"),
        lambda sha: gh_json(repository, f"commits/{sha}/pulls"),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.repository:
        parser.error("--repository or GITHUB_REPOSITORY is required")

    try:
        result = generate_from_repository(args.previous, args.current, args.repository)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ReleaseNotesError) as exc:
        parser.error(str(exc))
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(result["notes"])
    print("Contributors:")
    print(result["contributors_text"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
