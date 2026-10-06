"""Offline tests of the migration helper, not tests of the Solidity release."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("port_uniswap_v4", Path(__file__).with_name("port_uniswap_v4.py"))
port = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = port
SPEC.loader.exec_module(port)


class PortTests(unittest.TestCase):
    def entry(self, data=b"new\n", mode="100644"):
        return port.Entry(mode, port.blob_id(data))

    def test_scope_excludes_private_and_public_only_paths(self):
        for path in ("src/A.sol", "test/A.t.sol", "script/Deploy.s.sol", "package.json"):
            self.assertTrue(port.selected(path))
        for path in (".agents/a", ".github/workflows/ci.yml", ".env", "LICENSE",
                     "audits/a.pdf", "deployments/a", "README.md", "docs/research/a",
                     "../src/A.sol", "/src/A.sol", "src/../a", "src/.git/config"):
            self.assertFalse(port.selected(path), path)

    def test_plan_includes_add_modify_delete_and_mode_changes(self):
        src = {"src/add": self.entry(), "src/change": self.entry(),
               "script/run": self.entry(mode="100755"), "src/same": self.entry()}
        dst = {"src/remove": self.entry(), "src/change": self.entry(b"old\n"),
               "script/run": self.entry(), "src/same": self.entry()}
        self.assertEqual(port.changes(src, dst),
                         {"script/run": "M", "src/add": "A", "src/change": "M", "src/remove": "D"})

    def test_copy_preserves_public_material_and_file_modes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "src").mkdir()
            (root / "src/old.sol").write_bytes(b"old\n")
            (root / "LICENSE").write_text("keep license")
            (root / "audits").mkdir()
            (root / "audits/review.txt").write_text("keep audit")
            src = {"src/new.sol": self.entry(), "script/run.sh": self.entry(mode="100755")}
            dst = {"src/old.sol": self.entry(b"old\n")}
            port.apply_snapshot(root, src, dst, {path: b"new\n" for path in src})
            self.assertFalse((root / "src/old.sol").exists())
            self.assertEqual((root / "src/new.sol").read_bytes(), b"new\n")
            self.assertTrue((root / "script/run.sh").stat().st_mode & 0o111)
            self.assertEqual((root / "LICENSE").read_text(), "keep license")
            self.assertEqual((root / "audits/review.txt").read_text(), "keep audit")

    def test_preflight_rejects_ignored_collision_without_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "src").mkdir()
            (root / "src/new.sol").write_text("local data")
            with self.assertRaisesRegex(RuntimeError, "untracked/ignored"):
                port.apply_snapshot(root, {"src/new.sol": self.entry()}, {}, {"src/new.sol": b"new\n"})
            self.assertEqual((root / "src/new.sol").read_text(), "local data")

    def test_preflight_rejects_symlink_parent(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "elsewhere").mkdir()
            (root / "src").symlink_to(root / "elsewhere", target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                port.preflight(root, {"src/new.sol": self.entry()}, {})
            self.assertEqual(list((root / "elsewhere").iterdir()), [])

    def test_read_committed_bytes_not_dirty_source_worktree(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "src").mkdir()
            (root / "src/A.sol").write_bytes(b"committed\n")
            port.git(root, "add", ".")
            port.git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
            tracked = port.entries(root, "HEAD")
            (root / "src/A.sol").write_bytes(b"dirty\n")
            self.assertEqual(port.read_payload(root, tracked)["src/A.sol"], b"committed\n")

    def test_credential_like_content_is_stopped_before_copy(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            # Synthetic sentinel, not an actual private key or credential.
            data = b"-----BEGIN " + b"PRIVATE KEY-----\nfixture\n"
            blob = subprocess.run(["git", "-C", str(root), "hash-object", "-w", "--stdin"],
                                  input=data, capture_output=True, check=True).stdout.decode().strip()
            with self.assertRaisesRegex(RuntimeError, "Potential credential"):
                port.read_payload(root, {"src/key.txt": port.Entry("100644", blob)})


if __name__ == "__main__":
    unittest.main()
