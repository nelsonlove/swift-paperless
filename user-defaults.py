#!/usr/bin/env python3
"""Print the app group's shared UserDefaults as JSON.

Usage: user-defaults.py <folder> [app-group]

Finds <app-group>.plist under <folder> (for example a simulator's data folder).
The app group is the second argument, else the SWP_APP_GROUP environment
variable, else upstream's group.com.paulgessinger.swift-paperless; set it when
you build with your own SWP_APP_GROUP (see Config/Shared/Local.xcconfig.example).
"""

import sys
import json
import plistlib
from pathlib import Path
import os
import subprocess

DEFAULT_APP_GROUP = "group.com.paulgessinger.swift-paperless"

path = Path(sys.argv[1])
app_group = (
    sys.argv[2] if len(sys.argv) > 2 else os.environ.get("SWP_APP_GROUP", DEFAULT_APP_GROUP)
)

file = Path(
    subprocess.run(
        [
            "find",
            path,
            "-type",
            "f",
            "-name",
            f"{app_group}.plist",
        ],
        capture_output=True,
    )
    .stdout.decode("utf-8")
    .strip()
)

print(file)

with file.open("rb") as f:
    plist = plistlib.load(f)

output = {}

for key, value in plist.items():
    if isinstance(value, bytes):
        value = value.decode("utf-8")
        output[key] = json.loads(value)
    else:
        output[key] = value

print(json.dumps(output, indent=2))
