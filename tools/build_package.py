#!/usr/bin/env python3
"""Build and validate a deterministic PickThought plugin archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path
from typing import Dict, Iterable, Optional


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")


class PackageError(RuntimeError):
    """Raised when the plugin source or archive is not publishable."""


def validate_version(version: str) -> str:
    if not VERSION_RE.fullmatch(version):
        raise PackageError(f"invalid version: {version}")
    return version


def _read_assignment(path: Path, pattern: str, label: str) -> str:
    text = path.read_text(encoding="utf-8")
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        raise PackageError(f"expected one {label} in {path}")
    return matches[0]


def read_source_version(source_root: Path) -> str:
    plugin_root = source_root / "pickthought.koplugin"
    meta_version = _read_assignment(
        plugin_root / "_meta.lua",
        r'\bversion\s*=\s*"([^"]+)"',
        "_meta.lua version",
    )
    config_version = _read_assignment(
        plugin_root / "pickthought" / "config.lua",
        r'\bVERSION\s*=\s*"([^"]+)"',
        "config.lua version",
    )
    validate_version(meta_version)
    validate_version(config_version)
    if meta_version != config_version:
        raise PackageError(
            f"plugin versions differ: _meta.lua={meta_version}, config.lua={config_version}"
        )
    return meta_version


def _package_files(plugin_root: Path) -> Iterable[Path]:
    for path in sorted(plugin_root.rglob("*")):
        if path.is_file():
            yield path


def _package_bytes(path: Path) -> bytes:
    data = path.read_bytes()
    if path.suffix.lower() == ".lua":
        # Normalize checkout-specific line endings so local and CI packages match.
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return data


def _archive_version(archive: zipfile.ZipFile) -> str:
    try:
        meta = archive.read("pickthought.koplugin/_meta.lua").decode("utf-8")
        config = archive.read("pickthought.koplugin/pickthought/config.lua").decode("utf-8")
    except KeyError as exc:
        raise PackageError(f"missing required package file: {exc}") from exc

    meta_matches = re.findall(r'\bversion\s*=\s*"([^"]+)"', meta)
    config_matches = re.findall(r'\bVERSION\s*=\s*"([^"]+)"', config)
    if len(meta_matches) != 1 or len(config_matches) != 1:
        raise PackageError("could not read package versions")
    if meta_matches[0] != config_matches[0]:
        raise PackageError(
            f"archive versions differ: _meta.lua={meta_matches[0]}, config.lua={config_matches[0]}"
        )
    return validate_version(meta_matches[0])


def validate_archive(archive_path: Path, expected_version: Optional[str] = None) -> Dict[str, object]:
    archive_path = archive_path.resolve()
    if not archive_path.is_file():
        raise PackageError(f"archive does not exist: {archive_path}")

    with zipfile.ZipFile(archive_path, "r") as archive:
        names = archive.namelist()
        if not names:
            raise PackageError("archive is empty")
        for name in names:
            normalized = name.replace("\\", "/")
            if normalized.startswith("/") or "../" in normalized or normalized == "..":
                raise PackageError(f"unsafe archive path: {name}")
            if not normalized.startswith("pickthought.koplugin/"):
                raise PackageError(f"unexpected archive root: {name}")
        required = {
            "pickthought.koplugin/_meta.lua",
            "pickthought.koplugin/main.lua",
            "pickthought.koplugin/pickthought/config.lua",
        }
        missing = sorted(required.difference(names))
        if missing:
            raise PackageError("missing required package files: " + ", ".join(missing))
        version = _archive_version(archive)

    if expected_version is not None:
        validate_version(expected_version)
        if version != expected_version:
            raise PackageError(
                f"archive version mismatch: expected {expected_version}, actual {version}"
            )

    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    return {
        "version": version,
        "size": archive_path.stat().st_size,
        "sha256": digest,
        "path": str(archive_path),
    }


def build_package(
    source_root: Path,
    output_path: Path,
    expected_version: Optional[str] = None,
    metadata_path: Optional[Path] = None,
) -> Dict[str, object]:
    source_root = source_root.resolve()
    plugin_root = source_root / "pickthought.koplugin"
    if not plugin_root.is_dir():
        raise PackageError(f"plugin directory does not exist: {plugin_root}")

    source_version = read_source_version(source_root)
    if expected_version is not None:
        validate_version(expected_version)
        if source_version != expected_version:
            raise PackageError(
                f"source version mismatch: expected {expected_version}, actual {source_version}"
            )

    output_path = output_path.resolve()
    if output_path.parent == plugin_root or plugin_root in output_path.parents:
        raise PackageError("package output must be outside pickthought.koplugin")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()

    with zipfile.ZipFile(
        output_path,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for path in _package_files(plugin_root):
            name = path.relative_to(source_root).as_posix()
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.flag_bits = 0x800
            archive.writestr(info, _package_bytes(path))

    metadata = validate_archive(output_path, source_version)
    if metadata_path is not None:
        metadata_path = metadata_path.resolve()
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        metadata_path.write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--validate-archive", type=Path)
    args = parser.parse_args()

    try:
        if args.validate_archive:
            result = validate_archive(args.validate_archive, args.version)
        else:
            if not args.output:
                parser.error("--output is required when building a package")
            result = build_package(args.source, args.output, args.version, args.metadata)
    except PackageError as exc:
        parser.error(str(exc))
        return 2

    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
