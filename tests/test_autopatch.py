#!/usr/bin/env python3
"""Exercise autopatch against disposable Git repositories, never the source tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

UTILS = Path(__file__).resolve().parents[1]


class AutopatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="autopatch-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".repo").mkdir()
        self.utils = self.root / "vendor/intel/utils_vertical"
        self.utils.mkdir(parents=True)
        for name in ("autopatch.sh", "vendorsetup.sh", "patch_identity.py"):
            shutil.copy2(UTILS / name, self.utils / name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git(self.source, "init", "-q")
        self.git(self.source, "config", "user.name", "Patch test")
        self.git(self.source, "config", "user.email", "patch-test@example.invalid")
        self.env = dict(os.environ, TARGET_PRODUCT="caas")
        self.env.pop("OUT_DIR", None)
        self.env.update(GIT_AUTHOR_DATE="2025-01-01T00:00:00+00:00",
                        GIT_COMMITTER_DATE="2025-01-01T00:00:00+00:00")
        self.file = self.source / "file.txt"
        self.file.write_text("base\n")
        self.commit(self.source, "Base")
        self.base = self.git(self.source, "rev-parse", "HEAD").stdout.strip()
        self.patches = self.utils / "aosp_diff/caas/project"
        self.patches.mkdir(parents=True)
        # Different patches intentionally share their author date.
        self.env.update(GIT_AUTHOR_DATE="2025-02-01T00:00:00+00:00",
                        GIT_COMMITTER_DATE="2025-02-01T00:00:00+00:00")
        self.file.write_text("first\n")
        self.commit(self.source, "First patch")
        self.patch1 = self.git(self.source, "format-patch", "-1", "--stdout").stdout
        self.file.write_text("second\n")
        self.commit(self.source, "Second patch")
        self.patch2 = self.git(self.source, "format-patch", "-1", "--stdout").stdout
        self.project = self.root / "project"
        self.git(self.root, "clone", "--shared", "-q", str(self.source), str(self.project))
        self.git(self.project, "config", "user.name", "Patch test")
        self.git(self.project, "config", "user.email", "patch-test@example.invalid")
        self.git(self.project, "reset", "--hard", self.base)
        (self.patches / "0001.patch").write_text(self.patch1)

    def git(self, directory, *args, check=True):
        return subprocess.run(["git", "-C", str(directory), *args],
                              env=getattr(self, "env", None), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

    def commit(self, directory, subject):
        self.git(directory, "add", ".")
        self.git(directory, "commit", "-qm", subject)

    def autopatch(self, cwd=None):
        return subprocess.run(["bash", str(self.utils / "autopatch.sh")],
                              cwd=cwd or self.root, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_same_date_different_patches_both_apply(self):
        (self.patches / "0002.patch").write_text(self.patch2)
        result = self.autopatch(cwd=self.project)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.project / "file.txt").read_text(), "second\n")

    def test_repeat_preserves_local_edit_and_index(self):
        self.assertEqual(self.autopatch().returncode, 0)
        head = self.git(self.project, "rev-parse", "HEAD").stdout
        (self.project / "file.txt").write_text("local edit\n")
        before = self.git(self.project, "diff", "--binary").stdout
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.project, "diff", "--binary").stdout, before)
        self.assertEqual(self.git(self.project, "rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git(self.project, "diff", "--cached").stdout, "")

    def test_existing_patch_detected_without_receipt_with_local_edit(self):
        self.assertEqual(self.autopatch().returncode, 0)
        shutil.rmtree(self.project / ".git/celadon-autopatch")
        (self.project / "file.txt").write_text("local edit\n")
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.project / "file.txt").read_text(), "local edit\n")

    def test_receipt_invalid_after_reset(self):
        self.assertEqual(self.autopatch().returncode, 0)
        self.git(self.project, "reset", "--hard", self.base)
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.project / "file.txt").read_text(), "first\n")

    def test_modified_patch_body_is_not_skipped_using_old_source_hash(self):
        self.assertEqual(self.autopatch().returncode, 0)
        head = self.git(self.project, "rev-parse", "HEAD").stdout
        (self.patches / "0001.patch").write_text(self.patch1.replace("+first\n", "+revised\n"))
        result = self.autopatch()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.project, "rev-parse", "HEAD").stdout, head)

    def test_manually_adapted_backport_matches_change_id(self):
        change_id = "Change-Id: I" + "1" * 40
        (self.project / "file.txt").write_text("first\nbranch adaptation\n")
        self.commit(self.project, "First patch\n\n" + change_id)
        patch = self.patch1.replace("\n---\n", "\n" + change_id + "\n---\n", 1)
        (self.patches / "0001.patch").write_text(patch)
        head = self.git(self.project, "rev-parse", "HEAD").stdout
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.project, "rev-parse", "HEAD").stdout, head)

    def test_backport_with_changed_context_matches_exact_changed_lines(self):
        (self.project / "file.txt").write_text("base\nbranch context\n")
        self.commit(self.project, "Branch context")
        (self.project / "file.txt").write_text("first\nbranch context\n")
        self.commit(self.project, "First patch")
        (self.project / "file.txt").write_text("later change\nbranch context\n")
        self.commit(self.project, "Later change")
        head = self.git(self.project, "rev-parse", "HEAD").stdout
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.project, "rev-parse", "HEAD").stdout, head)

    def test_repeated_lunch_preserves_staged_and_unstaged_changes(self):
        self.assertEqual(self.autopatch().returncode, 0)
        (self.project / "file.txt").write_text("staged edit\n")
        self.git(self.project, "add", "file.txt")
        (self.project / "file.txt").write_text("unstaged edit\n")
        staged = self.git(self.project, "diff", "--cached", "--binary").stdout
        unstaged = self.git(self.project, "diff", "--binary").stdout
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.project, "diff", "--cached", "--binary").stdout, staged)
        self.assertEqual(self.git(self.project, "diff", "--binary").stdout, unstaged)

    def test_recovery_clears_marker(self):
        (self.project / "file.txt").write_text("local edit\n")
        self.assertNotEqual(self.autopatch().returncode, 0)
        self.git(self.project, "restore", "file.txt")
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.utils / "Android.mk").exists())

    def test_binary_patch_detected_after_later_commit(self):
        self.git(self.project, "cherry-pick", self.git(self.source, "rev-parse", "HEAD~1").stdout.strip())
        binary = self.project / "binary.dat"
        binary.write_bytes(b"\0first binary data\n")
        self.commit(self.project, "Binary patch")
        patch = self.git(self.project, "format-patch", "-1", "--stdout", "--binary").stdout
        (self.patches / "0002.patch").write_text(patch)
        binary.write_bytes(b"\0later binary data\n")
        self.commit(self.project, "Later binary change")
        head = self.git(self.project, "rev-parse", "HEAD").stdout
        # Change only the mail's source hash to model a cherry-picked patch.
        lines = patch.splitlines(True)
        lines[0] = "From " + "0" * 40 + " Mon Sep 17 00:00:00 2001\n"
        (self.patches / "0002.patch").write_text("".join(lines))
        result = self.autopatch()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.project, "rev-parse", "HEAD").stdout, head)
        self.assertEqual(binary.read_bytes(), b"\0later binary data\n")

    def test_new_patch_refuses_dirty_tree(self):
        (self.project / "file.txt").write_text("local edit\n")
        result = self.autopatch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Uncommitted changes", result.stdout)
        self.assertEqual((self.project / "file.txt").read_text(), "local edit\n")
        self.assertTrue((self.utils / "Android.mk").exists())

    def test_conflict_is_logged_aborted_and_stops_later_patches(self):
        (self.project / "file.txt").write_text("conflicting commit\n")
        self.commit(self.project, "Conflicting commit with same date")
        head = self.git(self.project, "rev-parse", "HEAD").stdout
        (self.patches / "0002.patch").write_text(self.patch2)
        result = self.autopatch()
        self.assertNotEqual(result.returncode, 0)
        logs = "".join(p.read_text() for p in (self.root / "out/autopatch").glob("*.log"))
        self.assertIn("Patch failed", logs)
        self.assertNotIn("Patch: " + str(self.patches / "./0002.patch"), logs)
        self.assertFalse((self.project / ".git/rebase-apply").exists())
        self.assertEqual(self.git(self.project, "rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git(self.project, "status", "--porcelain").stdout, "")

    def test_existing_am_operation_is_not_aborted(self):
        (self.project / "file.txt").write_text("conflicting commit\n")
        self.commit(self.project, "Conflict")
        result = self.git(self.project, "am", "-3", str(self.patches / "0001.patch"), check=False)
        self.assertNotEqual(result.returncode, 0)
        state = self.project / ".git/rebase-apply"
        self.assertTrue(state.is_dir())
        result = self.autopatch()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state.is_dir())

    def wrapper(self, aosp_status):
        build = self.root / "build"
        build.mkdir()
        (build / "envsetup.sh").write_text("function lunch()\n{\n    return 0\n}\n")
        product = self.root / "device/intel/product"
        product.mkdir(parents=True)
        (product / "caas.mk").touch()
        script = r'''
source vendor/intel/utils_vertical/vendorsetup.sh
gettop() { pwd; }
mixinup() { if [[ "$1" = -t ]]; then echo caas; else touch mixin-ran; fi; }
aosp_lunch() { return STATUS; }
lunch caas-userdebug
'''.replace("STATUS", str(aosp_status))
        return subprocess.run(["bash", "-c", script], cwd=self.root, env=self.env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_wrapper_stops_on_aosp_failure(self):
        result = self.wrapper(42)
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertFalse((self.root / "mixin-ran").exists())
        self.assertFalse((self.project / ".git/celadon-autopatch").exists())

    def test_wrapper_stops_on_patch_failure(self):
        (self.project / "file.txt").write_text("local edit\n")
        result = self.wrapper(0)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "mixin-ran").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
