import json
import tempfile
import unittest
from pathlib import Path

from tools.validate_manifest import ManifestError, validate_manifest


class ManifestTests(unittest.TestCase):
    def _write_manifest(self, directory: Path, **overrides):
        manifest = {
            "version": "0.3.1",
            "name": "撷思 PickThought 0.3.1",
            "package_type": "full",
            "package_url": "https://github.com/Mr54233/pickthought.koplugin/releases/download/v0.3.1/pickthought.koplugin.zip",
            "package_urls": [
                "https://github.com/Mr54233/pickthought.koplugin/releases/download/v0.3.1/pickthought.koplugin.zip"
            ],
            "size": 4,
            "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "notes": "问题修复：\n修复测试问题",
        }
        manifest.update(overrides)
        path = directory / "update.json"
        path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        return path

    def test_manifest_shape_is_valid(self):
        with tempfile.TemporaryDirectory() as temp:
            path = self._write_manifest(Path(temp))
            validate_manifest(path, "0.3.1")

    def test_manifest_version_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = self._write_manifest(Path(temp))
            with self.assertRaises(ManifestError):
                validate_manifest(path, "0.3.2")

    def test_manifest_package_hash_is_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = self._write_manifest(directory)
            package = directory / "package.zip"
            package.write_bytes(b"test")
            validate_manifest(path, "0.3.1", package)
            package.write_bytes(b"nope")
            with self.assertRaises(ManifestError):
                validate_manifest(path, "0.3.1", package)


if __name__ == "__main__":
    unittest.main()
