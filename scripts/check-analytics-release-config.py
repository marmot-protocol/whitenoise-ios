#!/usr/bin/env python3
"""Presence-only preflight for a built main-app Info.plist; never print keys."""
import plistlib
import sys
from urllib.parse import urlsplit

if len(sys.argv) != 2:
    sys.exit("usage: check-analytics-release-config.py <built-app/Info.plist>")
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
required = ["WhiteNoiseProductAnalyticsEndpoint", "WhiteNoiseProductAnalyticsAppKey",
            "WhiteNoiseProductAnalyticsOperator", "WhiteNoiseProductAnalyticsRetention"]
missing = [key for key in required if not isinstance(info.get(key), str)
           or not info[key].strip() or info[key].startswith("$(")]
if missing:
    sys.exit("Analytics rollout blocked: unresolved " + ", ".join(missing))
url = urlsplit(info[required[0]])
if url.scheme != "https" or not url.hostname or url.username or url.query or url.fragment:
    sys.exit("Analytics rollout blocked: invalid events endpoint")
print("Analytics configuration is resolved. Deployment retention, app separation, and persisted staging ingestion still require verification.")
