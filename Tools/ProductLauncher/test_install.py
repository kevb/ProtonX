#!/usr/bin/env python3
# Synthetic directory fixture. No installed app, profile, Keychain or UI accessed.
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("protonx_install", root / "scripts/install-app.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class AtomicInstallTests(unittest.TestCase):
    def bundle(self, root, name, version):
        bundle = root / name
        bundle.mkdir(parents=True)
        (bundle / "version").write_text(version)
        return bundle

    def test_swap_keeps_both_complete_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            old, new = base / "installed.app", base / "staged.app"
            old.mkdir(); new.mkdir()
            (old / "version").write_text("synthetic old")
            (new / "version").write_text("synthetic new")
            self.assertTrue(installer.publish(new, old))
            self.assertEqual((old / "version").read_text(), "synthetic new")
            self.assertEqual((new / "version").read_text(), "synthetic old")

    def test_first_install_and_failure_retain_staged_source(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            staged, installed = base / "staged.app", base / "installed.app"
            staged.mkdir(); (staged / "synthetic").write_text("fixture")
            self.assertFalse(installer.publish(staged, installed))
            self.assertTrue((installed / "synthetic").is_file())
            with self.assertRaises(OSError): installer.publish(base / "missing.app", installed)
            self.assertEqual((installed / "synthetic").read_text(), "fixture")

    def test_install_discards_previous_set_and_registers_new_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            destination = base / "Applications"
            sources = {name: self.bundle(base / "build", name, "synthetic new") for name in installer.IDENTITIES}
            for name in sources: self.bundle(destination, name, "synthetic old")
            with patch.object(installer, "verify"), patch.object(installer, "running", return_value=False), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as register:
                installed = installer.install(sources, destination)
            self.assertEqual(register.call_count, 9)
            for bundle in installed: self.assertEqual((bundle / "version").read_text(), "synthetic new")
            self.assertFalse((destination / ".ProtonX Previous Builds").exists())
            self.assertEqual([call.args[0][1] for call in register.call_args_list], ["-u", "-u", "-f"] * 3)
            self.assertEqual(list(destination.glob(".ProtonX-stage-*")), [])

    def test_running_installed_app_is_refused_before_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            destination = base / "Applications"
            source = self.bundle(base / "build", "ProtonX.app", "synthetic new")
            old = self.bundle(destination, "ProtonX.app", "synthetic old")
            with patch.object(installer, "verify"), patch.object(installer, "running", return_value=True), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as register:
                with self.assertRaises(RuntimeError): installer.install({"ProtonX.app": source}, destination)
            register.assert_not_called()
            self.assertEqual((old / "version").read_text(), "synthetic old")
            self.assertEqual(list(destination.iterdir()), [old])

    def test_interrupted_install_discards_staging_and_keeps_published_and_untouched_destinations(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            destination = base / "Applications"
            names = list(installer.IDENTITIES)[:2]
            sources = {name: self.bundle(base / "build", name, "synthetic new") for name in names}
            for name in sources: self.bundle(destination, name, "synthetic old")
            original_publish = installer.publish
            calls = 0
            def interrupted(staged, target):
                nonlocal calls
                calls += 1
                if calls == 2: raise OSError("synthetic interrupted publish")
                return original_publish(staged, target)
            with patch.object(installer, "verify"), patch.object(installer, "running", return_value=False), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), patch.object(installer, "publish", side_effect=interrupted):
                with self.assertRaises(OSError): installer.install(sources, destination)
            self.assertEqual((destination / names[0] / "version").read_text(), "synthetic new")
            self.assertEqual((destination / names[1] / "version").read_text(), "synthetic old")
            self.assertEqual(list(destination.glob(".ProtonX-stage-*")), [])
            self.assertFalse((destination / ".ProtonX Previous Builds").exists())
            for source in sources.values(): self.assertEqual((source / "version").read_text(), "synthetic new")

    def test_registration_failure_does_not_retain_old_app(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory); destination = base / "Applications"
            source = self.bundle(base / "build", "ProtonX.app", "synthetic new")
            installed = self.bundle(destination, "ProtonX.app", "synthetic old")
            with patch.object(installer, "verify"), patch.object(installer, "running", return_value=False), patch.object(installer.subprocess, "run", side_effect=OSError("synthetic registration failure")):
                with self.assertRaises(OSError): installer.install({"ProtonX.app": source}, destination)
            self.assertEqual((installed / "version").read_text(), "synthetic new")
            self.assertEqual((source / "version").read_text(), "synthetic new")
            self.assertEqual(list(destination.iterdir()), [installed])

    def test_unregistration_accepts_absent_registration_but_refuses_other_errors(self):
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "failed to scan: -10814", "")):
            installer.unregister(pathlib.Path("synthetic.app"))
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "synthetic access error")):
            with self.assertRaises(RuntimeError): installer.unregister(pathlib.Path("synthetic.app"))

    def test_staging_copy_failure_cleans_partial_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory); destination = base / "Applications"
            source = self.bundle(base / "build", "ProtonX.app", "synthetic new")
            installed = self.bundle(destination, "ProtonX.app", "synthetic old")
            with patch.object(installer, "verify"), patch.object(installer, "running", return_value=False), patch.object(installer.shutil, "copytree", side_effect=OSError("synthetic copy failure")):
                with self.assertRaises(OSError): installer.install({"ProtonX.app": source}, destination)
            self.assertEqual((installed / "version").read_text(), "synthetic old")
            self.assertEqual(list(destination.iterdir()), [installed])

if __name__ == "__main__": unittest.main()
