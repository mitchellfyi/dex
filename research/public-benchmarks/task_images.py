#!/usr/bin/env python3
"""Print the benchmark images a Harbor task pulls: its Dockerfile FROM lines and
task.toml docker_image, read from Harbor's task cache. run.sh removes them once
the task's job has finished.

Only images from benchmark registries are printed. A task built FROM a general
image such as python:3.13-slim shares it with the operator's own projects, and
deleting that is not this tool's call."""

import glob
import os
import re
import sys

FROM = re.compile(r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)", re.I | re.M)
PREBUILT = re.compile(r'^docker_image\s*=\s*"([^"]+)"', re.M)
BENCHMARK_IMAGE = re.compile(
    r"^(?:docker\.io/)?(?:jefzda/sweap-images|swebench/|xingyaoww/sweb|"
    r"ghcr\.io/laude-institute/|ghcr\.io/scaleapi/|ghcr\.io/epoch-research/)"
)

for task in sys.argv[1:]:
    for root in glob.glob(os.path.expanduser(f"~/.cache/harbor/tasks/*/{glob.escape(task)}")):
        dockerfile = os.path.join(root, "environment", "Dockerfile")
        if os.path.isfile(dockerfile):
            with open(dockerfile, encoding="utf-8", errors="replace") as handle:
                for image in FROM.findall(handle.read()):
                    if BENCHMARK_IMAGE.match(image):
                        print(image)
        toml = os.path.join(root, "task.toml")
        if os.path.isfile(toml):
            with open(toml, encoding="utf-8") as handle:
                for image in PREBUILT.findall(handle.read()):
                    if BENCHMARK_IMAGE.match(image):
                        print(image)
