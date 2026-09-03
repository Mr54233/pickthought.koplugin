import unittest

from tools.release_notes import ReleaseNotesError, generate_release_notes


class ReleaseNotesTests(unittest.TestCase):
    def test_notes_are_deduplicated_and_keep_references(self):
        commits = {
            "feature": {"author": {"login": "alice"}},
            "fix": {"author": {"login": "bob"}},
        }
        pulls = {
            "feature": [
                {
                    "number": 14,
                    "user": {"login": "reviewer"},
                    "body": "closes #16",
                }
            ],
            "fix": [],
        }
        result = generate_release_notes(
            [
                ("feature", "feat(ui): add runtime annotation style switching"),
                ("duplicate", "feat(ui): 增加运行时划线样式切换"),
                ("fix", "fix: 修复大文件磁盘中转误报失败"),
                ("popup", "fix(thought-popup): 修复跨页裁切并完善尺寸设置"),
            ],
            lambda sha: commits.get(sha, {"author": {}}),
            lambda sha: pulls.get(sha, []),
        )

        self.assertEqual(result["notes"].count("增加运行时划线样式切换"), 1)
        self.assertIn("Issue #14", result["notes"])
        self.assertIn("PR #10", result["notes"])
        self.assertIn("Issue #21", result["notes"])
        self.assertEqual(result["contributors"], ["alice", "bob", "reviewer"])

    def test_untranslated_subject_is_rejected(self):
        with self.assertRaises(ReleaseNotesError):
            generate_release_notes(
                [("sha", "fix: fix an English-only release entry")],
                lambda sha: {"author": {}},
                lambda sha: [],
            )


if __name__ == "__main__":
    unittest.main()
