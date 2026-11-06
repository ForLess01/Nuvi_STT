"""Offline distribution regressions. Every app/tool/path is a disposable fixture."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "A" * 40


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="nuvi-distribution-", dir="/private/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = self.root / "project"
        shutil.copytree(ROOT / "scripts", self.project / "scripts")
        (self.project / "Resources").mkdir()
        (self.project / "Sources/Nuvi/Infrastructure/Settings").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "com.nuvi.app", "CFBundleExecutable": "Nuvi",
                     "CFBundleShortVersionString": "2.2.2", "CFBundleVersion": "7"}
        (self.project / "Resources/Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.project / "Resources/Nuvi.entitlements").write_bytes(
            plistlib.dumps({"com.apple.security.device.audio-input": True}))
        (self.project / "Resources/Nuvi.icns").write_bytes(b"icon")
        (self.project / "Sources/Nuvi/Infrastructure/Settings/ModelsCatalog.json").write_text("[]")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.product = self.root / "product"
        self.product.mkdir()
        (self.product / "Nuvi").write_bytes(b"executable")
        (self.product / "Nuvi").chmod(0o755)
        (self.product / "Nuvi_Nuvi.bundle").mkdir()
        (self.product / "Nuvi_Nuvi.bundle/resource").write_bytes(b"resource")
        self.log = self.root / "calls.log"
        self.env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        HOME=str(self.root / "home"), NUVI_SIGN_IDENTITY=IDENTITY,
                        FIXTURE_ROOT=str(self.root), FIXTURE_PRODUCT=str(self.product),
                        FIXTURE_LOG=str(self.log), FIXTURE_IDENTITY=IDENTITY)
        Path(self.env["HOME"]).mkdir()
        self.tool("swift", 'if "--show-bin-path" in args: print(os.environ["FIXTURE_PRODUCT"])')
        self.tool("security", 'print(f\'  1) {os.environ["FIXTURE_IDENTITY"]} "Apple Development: Fixture (TEAM123456)"\\n  1 valid identities found\')')
        self.tool("codesign", '''
if "--force" in args:
    if os.environ.get("FAIL_SIGN") and "--entitlements" in args: sys.exit(12)
    sys.exit(0)
app = Path(args[-1])
if "--verify" in args:
    if (app / "invalid").exists(): sys.exit(3)
    if os.environ.get("FAIL_POSTCHECK") and str(app) == os.environ.get("TARGET") and (app / "Contents/MacOS/Nuvi").read_bytes() == b"candidate": sys.exit(4)
    sys.exit(0)
if "--entitlements" in args:
    import plistlib
    value = {} if (app / "missing-entitlement").exists() else {"com.apple.security.device.audio-input": True}
    sys.stdout.buffer.write(plistlib.dumps(value)); sys.exit(0)
if any(a.startswith("--extract-certificates") for a in args):
    opt = next(a for a in args if a.startswith("--extract-certificates"))
    # codesign's optional prefix must be attached to the option. A separate
    # argument is interpreted as a code path, not as the certificate prefix.
    if "=" not in opt:
        print("certificate prefix must use --extract-certificates=PREFIX", file=sys.stderr)
        sys.exit(1)
    prefix = opt.split("=", 1)[1]
    Path(prefix + "0").write_text("BB" if (app / "wrong-signer").exists() else "AA"); sys.exit(0)
runtime = "" if (app / "missing-runtime").exists() else "CodeDirectory flags=0x10000(runtime)"
print("Identifier=com.nuvi.app\\nAuthority=Apple Development: Fixture (TEAM123456)\\nTeamIdentifier=TEAM123456\\n" + runtime, file=sys.stderr)
''')
        self.tool("openssl", 'print("sha1 Fingerprint=" + ":".join([Path(args[args.index("-in")+1]).read_text()] * 20))')
        self.tool("lipo", 'print("arm64")')
        self.tool("pgrep", 'sys.exit(0 if os.environ.get("APP_RUNNING") else 1)')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\nimport os,sys\nfrom pathlib import Path\nargs=sys.argv[1:]\n"
                        "with open(os.environ['FIXTURE_LOG'],'a') as log: log.write(Path(sys.argv[0]).name+' '+repr(args)+'\\n')\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run(["/bin/bash", str(self.project / "scripts" / name), *map(str, args)],
                              env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=30)

    def make_app(self, path, content=b"candidate"):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources/Nuvi_Nuvi.bundle").mkdir(parents=True)
        (path / "Contents/MacOS/Nuvi").write_bytes(content)
        (path / "Contents/MacOS/Nuvi").chmod(0o755)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        (path / "Contents/Resources/ModelsCatalog.json").write_text("[]")
        (path / "Contents/Resources/Nuvi_Nuvi.bundle/resource").write_bytes(b"resource")

    def apps(self):
        target = self.root / "Applications/Nuvi.app"
        candidate = self.project / "build/Nuvi.app"
        self.make_app(target, b"original")
        self.make_app(candidate)
        self.env["TARGET"] = str(target)
        return candidate, target

    def install(self, candidate, target):
        return self.run_script("install-verified-app.sh", candidate, "--destination", target,
                               "--backup-root", self.root / "backups")

    def assert_original(self, target):
        self.assertEqual((target / "Contents/MacOS/Nuvi").read_bytes(), b"original")

    def test_build_success_preserves_interface(self):
        for config in ("debug", "release"):
            result = self.run_script("build-app.sh", config)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_script("build-app.sh", "invalid")
        self.assertEqual(result.returncode, 2)

    def test_verifier_uses_attached_certificate_prefix(self):
        candidate, _ = self.apps()
        result = self.run_script("verify-app.sh", candidate, "--identity", IDENTITY)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--extract-certificates=", self.log.read_text())

    def test_copy_comparison_ignores_only_provenance(self):
        candidate, target = self.apps()
        (target / "Contents/MacOS/Nuvi").write_bytes(b"candidate")
        # Simulate copy-specific provenance without changing the real protected
        # attribute. All other xattrs still use the actual macOS command.
        self.tool("xattr", '''
import subprocess
is_target = str(Path(args[-1]).resolve()).startswith(os.environ["TARGET"])
if args[:2] == ["-spx", "com.apple.provenance"]:
    print("01 02 AA" if is_target else "01 02 BB"); sys.exit(0)
result = subprocess.run(["/usr/bin/xattr", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
sys.stdout.buffer.write(result.stdout); sys.stdout.buffer.flush()
sys.stderr.buffer.write(result.stderr)
if args[0] == "-s" and (is_target or os.environ.get("PROVENANCE_BOTH")):
    print("com.apple.provenance")
sys.exit(result.returncode)
''')
        for both in ("1", ""):
            self.env["PROVENANCE_BOTH"] = both
            result = self.run_script("verify-app.sh", target, "--compare", candidate)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for attribute in ("com.apple.quarantine", "org.nuvi.fixture"):
            subprocess.run(["/usr/bin/xattr", "-w", attribute, "fixture", str(target)], check=True)
            result = self.run_script("verify-app.sh", target, "--compare", candidate)
            self.assertNotEqual(result.returncode, 0, attribute)
            subprocess.run(["/usr/bin/xattr", "-d", attribute, str(target)], check=True)

    def test_adhoc_and_unavailable_signer_rejected(self):
        for identity in ("-", "B" * 40):
            self.env["NUVI_SIGN_IDENTITY"] = identity
            result = self.run_script("build-app.sh")
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith("codesign ") for line in self.log.read_text().splitlines()))

    def test_failed_build_preserves_existing_output(self):
        candidate = self.project / "build/Nuvi.app"
        self.make_app(candidate, b"original")
        self.env["FAIL_SIGN"] = "1"
        self.assertNotEqual(self.run_script("build-app.sh").returncode, 0)
        self.assert_original(candidate)

    def test_signature_entitlement_runtime_and_identity_validation(self):
        candidate, _ = self.apps()
        for marker in ("invalid", "missing-entitlement", "missing-runtime"):
            (candidate / marker).touch()
            result = self.run_script("verify-app.sh", candidate)
            self.assertNotEqual(result.returncode, 0, marker + result.stdout + result.stderr)
            (candidate / marker).unlink()
        for args in (("--identity", "B" * 40), ("--version", "9.9.9"), ("--build", "9")):
            self.assertNotEqual(self.run_script("verify-app.sh", candidate, *args).returncode, 0)

    def test_invalid_candidate_leaves_original(self):
        candidate, target = self.apps()
        (candidate / "invalid").touch()
        self.assertNotEqual(self.install(candidate, target).returncode, 0)
        self.assert_original(target)

    def test_running_app_refuses_install(self):
        candidate, target = self.apps()
        self.env["APP_RUNNING"] = "1"
        self.assertNotEqual(self.install(candidate, target).returncode, 0)
        self.assert_original(target)
        self.assertFalse(any(line.startswith("codesign ") for line in self.log.read_text().splitlines()))

    def test_success_has_verified_rollback_and_metadata(self):
        candidate, target = self.apps()
        (candidate / "Contents/Resources/link").symlink_to("ModelsCatalog.json")
        subprocess.run(["/usr/bin/xattr", "-w", "org.nuvi.fixture", "metadata", str(candidate)], check=True)
        result = self.install(candidate, target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((target / "Contents/MacOS/Nuvi").read_bytes(), b"candidate")
        backups = list((self.root / "backups").glob("rollback.*/Nuvi.app"))
        self.assertEqual(len(backups), 1)
        self.assert_original(backups[0])
        self.assertEqual(self.run_script("verify-app.sh", target, "--compare", candidate).returncode, 0)

    def test_copy_comparison_rejects_payload_modes_symlinks_xattrs(self):
        candidate, target = self.apps()
        (target / "Contents/MacOS/Nuvi").write_bytes(b"candidate")
        binary = target / "Contents/MacOS/Nuvi"
        binary.chmod(0o700)
        self.assertNotEqual(self.run_script("verify-app.sh", target, "--compare", candidate).returncode, 0)
        binary.chmod(0o755)
        link = target / "Contents/Resources/link"
        link.symlink_to("ModelsCatalog.json")
        self.assertNotEqual(self.run_script("verify-app.sh", target, "--compare", candidate).returncode, 0)
        link.unlink()
        subprocess.run(["/usr/bin/xattr", "-w", "org.nuvi.fixture", "metadata", str(target)], check=True)
        self.assertNotEqual(self.run_script("verify-app.sh", target, "--compare", candidate).returncode, 0)

    def test_wrong_installed_signer_preserves_original(self):
        candidate, target = self.apps()
        (target / "wrong-signer").touch()
        self.assertNotEqual(self.install(candidate, target).returncode, 0)
        self.assert_original(target)

    def test_backup_and_stage_corruption_preserve_original(self):
        candidate, target = self.apps()
        self.tool("ditto", '''
import subprocess
result = subprocess.call(["/usr/bin/ditto", *args])
if os.environ["CORRUPT_COPY"] in args[-1]:
    (Path(args[-1]) / "Contents/MacOS/Nuvi").write_bytes(b"corrupt")
sys.exit(result)
''')
        for where in ("rollback.", ".Nuvi-install."):
            self.env["CORRUPT_COPY"] = where
            self.assertNotEqual(self.install(candidate, target).returncode, 0)
            self.assert_original(target)

    def test_first_install_and_invalid_source_symlink(self):
        candidate, target = self.apps()
        shutil.rmtree(target)
        result = self.install(candidate, target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        link = self.root / "candidate-link"
        link.symlink_to(candidate)
        self.assertNotEqual(self.install(link, target).returncode, 0)

    def test_stage_copy_failure_preserves_original(self):
        candidate, target = self.apps()
        self.tool("ditto", '''
import subprocess
if ".Nuvi-install." in args[-1]: sys.exit(8)
sys.exit(subprocess.call(["/usr/bin/ditto", *args]))
''')
        self.assertNotEqual(self.install(candidate, target).returncode, 0)
        self.assert_original(target)

    def test_rename_failures_restore_original(self):
        candidate, target = self.apps()
        self.tool("mv", '''
import subprocess
source, dest = args[-2:]
mode = os.environ["FAIL_MOVE"]
if mode == "original" and source == os.environ["TARGET"]: sys.exit(8)
if mode == "candidate" and ".Nuvi-install." in source and source.endswith("/Nuvi.app"): sys.exit(8)
sys.exit(subprocess.call(["/bin/mv", *args]))
''')
        for mode in ("original", "candidate"):
            self.env["FAIL_MOVE"] = mode
            result = self.install(candidate, target)
            self.assertNotEqual(result.returncode, 0)
            self.assert_original(target)

    def test_unsafe_backup_root_rejected_without_mutating_apps(self):
        candidate, target = self.apps()
        unsafe = candidate / "new-backup"
        result = self.run_script("install-verified-app.sh", candidate, "--destination", target,
                                 "--backup-root", unsafe)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(unsafe.exists())
        self.assert_original(target)

    def test_restore_failure_retains_recoverable_original(self):
        candidate, target = self.apps()
        self.tool("mv", '''
import subprocess
if ".Nuvi-install." in args[-2]: sys.exit(8)
sys.exit(subprocess.call(["/bin/mv", *args]))
''')
        result = self.install(candidate, target)
        self.assertNotEqual(result.returncode, 0)
        originals = list(target.parent.glob(".Nuvi-install.*/previous-Nuvi.app"))
        self.assertEqual(len(originals), 1)
        self.assert_original(originals[0])
        self.assertIn("Recovery required", result.stderr)

    def test_missing_resource_or_invalid_metadata_rejected(self):
        candidate, target = self.apps()
        shutil.rmtree(candidate / "Contents/Resources/Nuvi_Nuvi.bundle")
        self.assertNotEqual(self.install(candidate, target).returncode, 0)
        self.assert_original(target)
        (candidate / "Contents/Resources/Nuvi_Nuvi.bundle").mkdir()
        self.info["CFBundleIdentifier"] = "other.app"
        (candidate / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.assertNotEqual(self.install(candidate, target).returncode, 0)
        self.assert_original(target)

    def test_postcheck_failure_restores_original(self):
        candidate, target = self.apps()
        self.env["FAIL_POSTCHECK"] = "1"
        result = self.install(candidate, target)
        self.assertNotEqual(result.returncode, 0)
        self.assert_original(target)
        self.assertNotIn("Installed and verified", result.stdout)

    def test_failed_signing_never_retries_without_entitlements(self):
        self.env["FAIL_SIGN"] = "1"
        result = self.run_script("build-app.sh", "release")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [line for line in self.log.read_text().splitlines() if line.startswith("codesign ") and "--force" in line]
        self.assertEqual(len(calls), 1, calls)
        self.assertNotIn("==> Done.", result.stdout)

    def test_failed_copy_keeps_original(self):
        target = self.root / "Applications/Nuvi.app"
        self.make_app(target, b"original")
        candidate = self.project / "build/Nuvi.app"
        self.make_app(candidate)
        self.tool("cp", 'sys.exit(9)')
        helper = self.project / "scripts/install-verified-app.sh"
        if helper.exists():
            self.tool("ditto", 'sys.exit(9)')
            result = self.run_script("install-verified-app.sh", candidate, "--destination", target,
                                     "--backup-root", self.root / "backups")
        else:
            # Baseline-only safe fixture: no command can name the real /Applications.
            installer = self.project / "scripts/install-app.sh"
            installer.write_text(installer.read_text().replace('INSTALLED="/Applications/Nuvi.app"',
                                 f'INSTALLED="{target}"'))
            build = self.project / "scripts/build-app.sh"
            build.write_text("#!/bin/bash\nexit 0\n"); build.chmod(0o755)
            result = self.run_script("install-app.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((target / "Contents/MacOS/Nuvi").exists(), "Original app was removed before copy succeeded")
        self.assertEqual((target / "Contents/MacOS/Nuvi").read_bytes(), b"original")


if __name__ == "__main__":
    unittest.main()
