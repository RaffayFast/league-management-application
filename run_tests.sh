#!/usr/bin/env sh
# Backend suite (Phase I contract, Groups 1-3). Browser (tests/selenium) and device (tests/appium)
# suites need running infrastructure and are run separately; see README.md.
set -e
cd "$(dirname "$0")"
PYTHONDONTWRITEBYTECODE=1 python -m pytest -q --ignore=tests/selenium --ignore=tests/appium "$@"
