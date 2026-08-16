#!/usr/bin/env python3
"""Validate an already-built PickThought package."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from build_package import PackageError, validate_archive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version")
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()

    try:
        metadata = validate_archive(args.archive, args.version)
    except PackageError as exc:
        parser.error(str(exc))
        return 2

    if args.metadata:
        args.metadata.parent.mkdir(parents=True, exist_ok=True)
        args.metadata.write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(metadata, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
