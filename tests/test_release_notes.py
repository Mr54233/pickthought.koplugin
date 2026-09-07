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

    def test_refactor_commits_get_their_own_section(self):
        # 0.5.1 整改轮:refactor 前缀的提交(菜单收纳/弹窗基类)需要出现在
        # 发布摘要的「结构调整」段,而不是被静默跳过。
        result = generate_release_notes(
            [("remediation", "refactor(remediation): 日志收敛、弹窗基类收敛与菜单抽离")],
            lambda _sha: {"author": {"login": "Mr54233"}},
            lambda _sha: [],
        )
        self.assertIn("结构调整：\n日志收敛、弹窗基类收敛与菜单抽离", result["notes"])
        self.assertEqual(result["contributors"], ["Mr54233"])

    def test_untranslated_subject_is_rejected(self):
        with self.assertRaises(ReleaseNotesError):
            generate_release_notes(
                [("sha", "fix: fix an English-only release entry")],
                lambda sha: {"author": {}},
                lambda sha: [],
            )


if __name__ == "__main__":
    unittest.main()
