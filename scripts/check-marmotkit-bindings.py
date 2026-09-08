#!/usr/bin/env python3
"""Check published binding provenance without changing package sources."""
import json
import pathlib
import re
import subprocess
import tempfile


VERSION_FIELDS = {
    "mdk-sha": "mdkSHA",
    "mdk-tag": "mdkTag",
    "published-at": "builtAt",
    "uniffi-version": "uniffiVersion",
    "features": "features",
}


def check_coherence(provenance, package, compiled_version):
    for field in (*VERSION_FIELDS, "swiftpm-checksum"):
        if not provenance.get(field):
            raise ValueError(f"missing published provenance: {field}")
    for field in VERSION_FIELDS:
        if compiled_version.get(field) != provenance[field]:
            raise ValueError(f"compiled MarmotKitVersion disagrees with MARMOT_VERSION: {field}")
    if not re.fullmatch(r"[0-9a-f]{40}", provenance["mdk-sha"]):
        raise ValueError("invalid source SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", provenance["swiftpm-checksum"]):
        raise ValueError("invalid binary checksum")
    tag = provenance["mdk-tag"]
    if tag.startswith("marmotkit-snapshot-"):
        release = "snapshot-" + provenance["mdk-sha"]
        if tag != "marmotkit-" + release:
            raise ValueError("snapshot tag disagrees with source SHA")
    elif re.fullmatch(r"marmotkit-v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?", tag):
        release = tag.removeprefix("marmotkit-v")
    else:
        raise ValueError("expected a published MarmotKit snapshot or release tag")
    expected_url = ("https://github.com/marmot-protocol/mdk/releases/download/"
                    f"{tag}/MarmotKitFFI-{release}.xcframework.zip")
    targets = [target for target in package.get("targets", []) if target.get("name") == "MarmotKitFFI"]
    if len(targets) != 1 or targets[0].get("type") != "binary":
        raise ValueError("expected one MarmotKitFFI binary target")
    target = targets[0]
    if target.get("path") or target.get("url") != expected_url:
        raise ValueError("binary target must use the recorded immutable release URL")
    if target.get("checksum") != provenance["swiftpm-checksum"]:
        raise ValueError("binary target checksum disagrees with MARMOT_VERSION")


def main():
    package_dir = pathlib.Path(__file__).resolve().parents[1] / "Packages/MarmotKit"
    provenance = {}
    for line in (package_dir / "MARMOT_VERSION").read_text().splitlines():
        if not line.strip():
            break
        key, value = line.split(":", 1)
        provenance[key] = value.strip()
    with tempfile.TemporaryDirectory(prefix="marmotkit-coherence-") as root:
        scratch = pathlib.Path(root)
        package = json.loads(subprocess.check_output([
            "swift", "package", "--package-path", str(package_dir),
            "--scratch-path", str(scratch / "package"), "dump-package",
        ], text=True))
        # Execute the version constants instead of matching Swift source spelling.
        values = ",\n".join(f'"{field}": MarmotKitVersion.{member}' for field, member in VERSION_FIELDS.items())
        driver = scratch / "ReadVersion.swift"
        driver.write_text("import Foundation\n@main enum ReadVersion {\n"
                          "static func main() throws {\nlet values: [String: String] = [\n"
                          + values + "\n]\nFileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: values))\n}}\n")
        executable = scratch / "read-version"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(package_dir / "Sources/MarmotKit/MarmotKitVersion.swift"),
                        str(driver), "-o", str(executable)], check=True)
        compiled_version = json.loads(subprocess.check_output([str(executable)], text=True))
    check_coherence(provenance, package, compiled_version)
    print("Published MarmotKit package and version provenance agree.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"MarmotKit coherence check failed: {error}") from error
