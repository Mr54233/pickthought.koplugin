import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WorkflowContractTests(unittest.TestCase):
    def _read(self, name: str) -> str:
        return (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")

    def test_ci_runs_reusable_quality_on_pull_requests_and_main(self):
        workflow = self._read("ci.yml")
        self.assertIn("pull_request:", workflow)
        self.assertIn("branches:\n      - main", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("uses: ./.github/workflows/quality.yml", workflow)
        self.assertNotIn("skip_tests", workflow)

    def test_quality_cannot_skip_without_reusable_input(self):
        workflow = self._read("quality.yml")
        self.assertIn("workflow_call:", workflow)
        self.assertIn("skip_tests:", workflow)
        self.assertIn("if: ${{ !inputs.skip_tests }}", workflow)
        self.assertIn("luajit tests/run.lua", workflow)
        self.assertIn("python3 -m unittest discover", workflow)
        self.assertRegex(workflow, r"actions/upload-artifact@(v\d+|[0-9a-f]{40})")

    def test_release_requires_quality_or_explicit_manual_skip(self):
        workflow = self._read("release.yml")
        self.assertIn('tags:\n      - "v*"', workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("needs: quality", workflow)
        self.assertIn("needs.quality.result == 'success'", workflow)
        self.assertIn("needs.quality.result == 'skipped' && inputs.skip_tests == true", workflow)
        self.assertRegex(workflow, r"actions/download-artifact@(v\d+|[0-9a-f]{40})")
        self.assertIn("tools/validate_manifest.py", workflow)
        self.assertRegex(workflow, r"softprops/action-gh-release@(v\d+|[0-9a-f]{40})")


if __name__ == "__main__":
    unittest.main()
