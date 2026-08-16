#!/usr/bin/env python3
"""Prepare version files and update.json before creating a release tag."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.build_package import PackageError, build_package, validate_version  # noqa: E402
from tools.release_notes import generate_from_repository  # noqa: E402


MIRROR_PREFIXES = [
    "https://ghfast.top/",
    "https://gh-proxy.com/",
    "https://ghproxy.net/",
]


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True, encoding="utf-8").strip()


def update_version(path: Path, pattern: str, version: str) -> str:
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, lambda match: match.group(1) + version + match.group(3), original, count=1)
    if count != 1:
        raise PackageError(f"could not update version in {path}")
    path.write_text(updated, encoding="utf-8")
    return original


def package_url(version: str) -> str:
    return (
        "https://github.com/Mr54233/pickthought.koplugin/releases/"
        f"download/v{version}/pickthought.koplugin.zip"
    )


def prepare(
    version: str,
    previous_tag: str,
    repository: str,
    package_output: Optional[Path],
) -> dict:
    validate_version(version)
    dirty = git("status", "--porcelain", "--untracked-files=no")
    if dirty:
        raise PackageError("工作区有未提交的跟踪文件，请先提交或清理后再准备发版")

    meta_path = ROOT / "pickthought.koplugin" / "_meta.lua"
    config_path = ROOT / "pickthought.koplugin" / "pickthought" / "config.lua"
    manifest_path = ROOT / "update.json"
    original_meta = meta_path.read_text(encoding="utf-8")
    original_config = config_path.read_text(encoding="utf-8")
    original_manifest = manifest_path.read_text(encoding="utf-8")

    try:
        update_version(meta_path, r'(version\s*=\s*")([^"]+)(")', version)
        update_version(config_path, r'(VERSION\s*=\s*")([^"]+)(")', version)

        if package_output is None:
            temp_dir = tempfile.TemporaryDirectory()
            output_path = Path(temp_dir.name) / "pickthought.koplugin.zip"
        else:
            temp_dir = None
            output_path = package_output.resolve()

        try:
            metadata = build_package(ROOT, output_path, expected_version=version)
        finally:
            if temp_dir is not None:
                temp_dir.cleanup()

        notes = generate_from_repository(previous_tag, "HEAD", repository)
        url = package_url(version)
        manifest = json.loads(original_manifest)
        manifest.update(
            {
                "version": version,
                "name": f"撷思 PickThought {version}",
                "package_type": "full",
                "package_url": url,
                "package_urls": [url] + [prefix + url for prefix in MIRROR_PREFIXES],
                "size": metadata["size"],
                "sha256": metadata["sha256"],
                "notes": notes["notes"],
            }
        )
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        return {"version": version, "metadata": metadata, "notes": notes}
    except Exception:
        meta_path.write_text(original_meta, encoding="utf-8")
        config_path.write_text(original_config, encoding="utf-8")
        manifest_path.write_text(original_manifest, encoding="utf-8")
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--previous-tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--package-output", type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.version, args.previous_tag, args.repository, args.package_output)
    except (PackageError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
        return 2

    metadata = result["metadata"]
    print(f"已准备 v{result['version']}")
    print(f"包大小：{metadata['size']} 字节")
    print(f"SHA-256：{metadata['sha256']}")
    print("接下来请检查版本文件和 update.json，提交后再推送 main 并创建同版本 tag。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
