#!/usr/bin/env python3
"""Build a Lambda layer package (zip) from one or more requirements.txt files.

This is used from Terraform via the external data source.

Input (JSON via stdin):
  {
    "build_dir": "/abs/path/to/_layer_b3",
    "requirements": ["/abs/path/to/requirements1.txt", "/abs/path/to/requirements2.txt"],
    "output_zip": "/abs/path/to/b3_layer.zip",
    "python_version": "3.12"
  }

Output (JSON to stdout):
  {"zip_path": "/abs/path/to/b3_layer.zip"}
"""

import json
import os
import shutil
import subprocess
import sys


def fail(msg):
    print(json.dumps({"error": msg}))
    sys.exit(1)


def main():
    inp = json.load(sys.stdin)

    build_dir = inp.get("build_dir")
    requirements = inp.get("requirements")
    output_zip = inp.get("output_zip")
    python_version = inp.get("python_version", "3.12")

    if not build_dir or not requirements or not output_zip:
        fail("Missing required input. Expected build_dir, requirements, output_zip.")

    if isinstance(requirements, str):
        try:
            requirements = json.loads(requirements)
        except Exception:
            requirements = [requirements]

    build_python_dir = os.path.join(build_dir, "python")

    # Clean and prepare build directory
    if os.path.exists(build_dir):
        shutil.rmtree(build_dir)
    os.makedirs(build_python_dir, exist_ok=True)

    # Install requirements into layer build directory
    for req in requirements:
        if not os.path.exists(req):
            fail(f"Requirements file not found: {req}")

        cmd = [
            sys.executable,
            "-m",
            "pip",
            "install",
            "-r",
            req,
            "-t",
            build_python_dir,
            "--platform",
            "manylinux2014_x86_64",
            "--only-binary=:all:",
            "--python-version",
            python_version,
            "--upgrade",
        ]

        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as e:
            fail(f"pip install failed: {e}")

    # Ensure the layer isn't empty
    if not any(os.scandir(build_python_dir)):
        fail("Layer directory is empty after pip install")

    # Create zip archive
    base_dir = os.path.dirname(output_zip)
    os.makedirs(base_dir, exist_ok=True)

    if os.path.exists(output_zip):
        os.remove(output_zip)

    shutil.make_archive(output_zip.replace(".zip", ""), "zip", build_dir)

    print(json.dumps({"zip_path": output_zip}))


if __name__ == "__main__":
    main()
