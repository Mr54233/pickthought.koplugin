import tempfile
import unittest
from pathlib import Path

from tools.build_package import PackageError, build_package


class BuildPackageTests(unittest.TestCase):
    def _source(self, directory: Path):
        plugin = directory / "pickthought.koplugin"
        (plugin / "pickthought").mkdir(parents=True)
        (plugin / "_meta.lua").write_text('return { version = "1.2.3" }\n', encoding="utf-8")
        (plugin / "main.lua").write_text("return true\n", encoding="utf-8")
        (plugin / "pickthought" / "config.lua").write_text(
            'return { VERSION = "1.2.3" }\n', encoding="utf-8"
        )
        (plugin / "LICENSE").write_text("License line 1\nLicense line 2\n", encoding="utf-8")

    def test_build_is_byte_for_byte_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._source(root)
            first = root / "first.zip"
            second = root / "second.zip"
            build_package(root, first, expected_version="1.2.3")
            build_package(root, second, expected_version="1.2.3")
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_source_version_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._source(root)
            with self.assertRaises(PackageError):
                build_package(root, root / "package.zip", expected_version="1.2.4")

    def test_crlf_sources_are_normalized_in_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._source(root)
            plugin = root / "pickthought.koplugin"
            for path in list(plugin.rglob("*.lua")) + [plugin / "LICENSE"]:
                path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))

            archive_path = root / "package.zip"
            build_package(root, archive_path, expected_version="1.2.3")

            import zipfile

            with zipfile.ZipFile(archive_path) as archive:
                for name in archive.namelist():
                    self.assertNotIn(b"\r", archive.read(name))


if __name__ == "__main__":
    unittest.main()
