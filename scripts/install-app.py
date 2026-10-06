#!/usr/bin/env python3
"""Install verified local builds and launchers. Never modify account/profile data.

macOS atomic directory swaps preserve a previous bundle for rollback. Running
installed binaries are refused. Build-directory copies may remain running, but
launchers ask the user to quit those before opening the installed app.
"""
import argparse
import ctypes
import datetime
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import uuid

IDENTITIES = {"ProtonX.app": "org.kevb.ProtonX", "ProtonX Mail.app": "org.kevb.ProtonX.MailLauncher", "ProtonX Pass.app": "org.kevb.ProtonX.PassLauncher"}

def verify(bundle, identity):
    if bundle.is_symlink() or not bundle.is_dir():
        raise RuntimeError("Use a real, built app bundle.")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != identity or info.get("CFBundlePackageType") != "APPL":
        raise RuntimeError("App identity differs from the expected ProtonX build.")
    if any(path.is_symlink() for path in bundle.rglob("*")):
        raise RuntimeError("This installer does not accept linked bundle contents.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return info

def running(bundle):
    if not bundle.exists(): return False
    executables = list((bundle / "Contents/MacOS").glob("*")) + list((bundle / "Contents/Helpers").glob("*"))
    for executable in executables:
        result = subprocess.run(["/usr/sbin/lsof", "-t", str(executable)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode == 0: return True
        if result.returncode != 1: raise RuntimeError("Could not establish whether the installed app is running.")
    return False

def publish(staged, destination):
    """No missing-bundle interval: swap same-volume directories on macOS."""
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # Darwin AT_FDCWD=-2. RENAME_SWAP=2; RENAME_EXCL=4 (no replacement).
    flags = 2 if destination.exists() else 4
    if rename(-2, os.fsencode(staged), -2, os.fsencode(destination), flags) != 0:
        raise OSError(ctypes.get_errno(), "Could not publish the verified app bundle.")
    return flags == 2

def install(sources, directory):
    directory.mkdir(parents=True, exist_ok=True)
    if directory.is_symlink(): raise RuntimeError("The installation directory must not be a symlink.")
    # Validate the entire set before writing any installed bundle.
    for name, source in sources.items():
        verify(source, IDENTITIES[name])
        destination = directory / name
        if destination.exists(): verify(destination, IDENTITIES[name])
        if destination.is_symlink() or running(destination):
            raise RuntimeError("Quit the installed ProtonX app/launchers before updating. Files have been retained.")
    previous = directory / ".ProtonX Previous Builds"
    if previous.is_symlink() or (previous.exists() and not previous.is_dir()):
        raise RuntimeError("The previous-builds location is invalid; nothing was changed.")
    previous.mkdir(mode=0o700, exist_ok=True)
    stage = pathlib.Path(tempfile.mkdtemp(prefix=".ProtonX-stage-", dir=directory))
    complete = False
    try:
        for name, source in sources.items():
            target = stage / name
            shutil.copytree(source, target)
            verify(target, IDENTITIES[name])
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        backup = previous / stamp
        backup.mkdir(mode=0o700)
        for name in sources:
            destination, staged = directory / name, stage / name
            if running(destination): raise RuntimeError("ProtonX opened during installation. Close it and retry.")
            replaced = publish(staged, destination)
            if replaced:
                # The swapped previous build stays recoverable, outside Spotlight.
                shutil.move(str(staged), str(backup / name))
            verify(destination, IDENTITIES[name])
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(destination)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        complete = True
    finally:
        if complete:
            shutil.rmtree(stage)
        # On interruption/failure keep staged and swapped previous bundles for
        # explicit recovery. Never erase the old build in exception cleanup.
    return [directory / name for name in sources]

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--destination", type=pathlib.Path, default=pathlib.Path("/Applications"))
    parser.add_argument("--launchers", type=pathlib.Path)
    args = parser.parse_args()
    sources = {"ProtonX.app": args.app.resolve()}
    if args.launchers:
        sources.update({name: (args.launchers / name).resolve() for name in ["ProtonX Mail.app", "ProtonX Pass.app"]})
    try:
        for installed in install(sources, args.destination.absolute()): print(installed)
    except (RuntimeError, OSError, subprocess.CalledProcessError, ValueError) as error:
        raise SystemExit("Installation stopped safely: " + str(error))
