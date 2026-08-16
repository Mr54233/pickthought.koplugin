#!/usr/bin/env python3
"""Validate update.json and optionally compare it with a package."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Dict, Optional


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ManifestError(ValueError):
    pass


def validate_manifest(
    manifest_path: Path,
    expected_version: Optional[str] = None,
    package_path: Optional[Path] = None,
) -> Dict[str, object]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"invalid manifest: {manifest_path}") from exc
    if not isinstance(manifest, dict):
        raise ManifestError("manifest must be a JSON object")

    required = {
        "version",
        "name",
        "package_type",
        "package_url",
        "package_urls",
        "size",
        "sha256",
        "notes",
    }
    missing = sorted(required.difference(manifest))
    if missing:
        raise ManifestError("missing manifest fields: " + ", ".join(missing))

    version = manifest["version"]
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ManifestError(f"invalid manifest version: {version}")
    if expected_version is not None and version != expected_version:
        raise ManifestError(
            f"manifest version mismatch: expected {expected_version}, actual {version}"
        )
    if manifest["package_type"] != "full":
        raise ManifestError("package_type must be full")
    if not isinstance(manifest["package_url"], str) or not manifest["package_url"]:
        raise ManifestError("package_url must be a non-empty string")
    urls = manifest["package_urls"]
    if not isinstance(urls, list) or not urls or not all(isinstance(url, str) and url for url in urls):
        raise ManifestError("package_urls must be a non-empty string list")
    if manifest["package_url"] not in urls:
        raise ManifestError("package_url must be included in package_urls")
    if not isinstance(manifest["size"], int) or manifest["size"] <= 0:
        raise ManifestError("size must be a positive integer")
    if not isinstance(manifest["sha256"], str) or not SHA256_RE.fullmatch(manifest["sha256"]):
        raise ManifestError("sha256 must be a lowercase SHA-256 value")
    if not isinstance(manifest["notes"], str) or not manifest["notes"].strip():
        raise ManifestError("notes must be a non-empty string")
    if f"/v{version}/" not in manifest["package_url"]:
        raise ManifestError("package_url does not contain the manifest version")

    if package_path is not None:
        package_bytes = package_path.read_bytes()
        package_size = len(package_bytes)
        package_sha = hashlib.sha256(package_bytes).hexdigest()
        if package_size != manifest["size"]:
            raise ManifestError(
                f"package size mismatch: manifest={manifest['size']}, actual={package_size}"
            )
        if package_sha != manifest["sha256"]:
            raise ManifestError(
                f"package sha256 mismatch: manifest={manifest['sha256']}, actual={package_sha}"
            )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--version")
    parser.add_argument("--package", type=Path)
    args = parser.parse_args()
    try:
        manifest = validate_manifest(args.manifest, args.version, args.package)
    except (ManifestError, OSError) as exc:
        parser.error(str(exc))
        return 2
    print(json.dumps(manifest, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
