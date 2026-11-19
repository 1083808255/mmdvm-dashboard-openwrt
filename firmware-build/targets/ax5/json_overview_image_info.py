#!/usr/bin/env python3

from os import getenv, environ
from pathlib import Path
from subprocess import run, PIPE
from sys import argv
import json

if len(argv) != 2:
    print("JSON info files script requires output file as argument")
    exit(1)

output_path = Path(argv[1])

assert getenv("WORK_DIR"), "$WORK_DIR required"

work_dir = Path(getenv("WORK_DIR"))

output = {}


def get_initial_output(image_info):
    # preserve existing profiles.json
    if output_path.is_file():
        profiles = json.loads(output_path.read_text())
        if profiles["version_code"] == image_info["version_code"]:
            return profiles
    return image_info


for json_file in work_dir.glob("*.json"):
    image_info = json.loads(json_file.read_text())

    if not output:
        output = get_initial_output(image_info)

    # get first and only profile in json file
    device_id, profile = next(iter(image_info["profiles"].items()))
    if device_id not in output["profiles"]:
        output["profiles"][device_id] = profile
    else:
        output["profiles"][device_id]["images"].extend(profile["images"])

# make image lists unique by name, keep last/latest
for device_id, profile in output.get("profiles", {}).items():
    profile["images"] = list({e["name"]: e for e in profile["images"]}.values())


if output:
    # 兼容 make -w/MAKEFLAGS 带来的额外输出行：只取非空行，
    # 最后一行为 ARCH_PACKAGES，其余行合并为 DEFAULT_PACKAGES
    lines = [
        line for line in run(
            [
                "make",
                "--no-print-directory",
                "-C",
                "target/linux/",
                "val.DEFAULT_PACKAGES",
                "val.ARCH_PACKAGES",
            ],
            stdout=PIPE,
            stderr=PIPE,
            check=True,
            env=dict(environ, TOPDIR=str(Path().cwd()), MAKEFLAGS=""),
            universal_newlines=True,
        ).stdout.splitlines() if line.strip()
    ]

    output["arch_packages"] = lines[-1]
    output["default_packages"] = sorted(" ".join(lines[:-1]).split())

    output_path.write_text(json.dumps(output, sort_keys=True, separators=(",", ":")))
else:
    print("JSON info file script could not find any JSON files for target")
