#!/usr/bin/env bash
# Build a clean, pinned MDK checkout. Local artifacts are never committed.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'usage: scripts/sync-local-bindings.sh <mdk-checkout> <full-master-sha>' >&2
  exit 2
fi
local_mdk="$(cd "$1" && pwd)"
source_sha="$2"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$(git -C "$local_mdk" rev-parse HEAD)" == "$source_sha" ]] || { echo 'MDK checkout does not match requested SHA' >&2; exit 1; }
[[ -z "$(git -C "$local_mdk" status --porcelain)" ]] || { echo 'MDK checkout must be clean' >&2; exit 1; }
ios_root="$(cd "$(dirname "$0")/.." && pwd)"
export OTLP_EXPORT=1 PRODUCT_ANALYTICS_EXPORT=1
"$local_mdk/crates/marmot-uniffi/xcframework.sh"
[[ "$(git -C "$local_mdk" rev-parse HEAD)" == "$source_sha" && -z "$(git -C "$local_mdk" status --porcelain)" ]] || exit 1
"$local_mdk/crates/marmot-uniffi/validate-ios-artifact.sh" "$local_mdk/crates/marmot-uniffi/output/MarmotKit.xcframework" 18.0
(
  cd "$local_mdk"
  ./crates/marmot-uniffi/package-ios-artifacts.sh "local-$source_sha" "local-$source_sha" "$source_sha" "$ios_root/build/local-marmotkit" "$source_sha"
)
python3 - "$local_mdk" "$ios_root" "$source_sha" <<'PY'
from pathlib import Path
import datetime,hashlib,json,shutil,subprocess,sys
mdk,root,sha=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
package=root/'Packages/MarmotKit'
manifest=json.loads((root/f'build/local-marmotkit/marmotkit-ios-local-{sha}.manifest.json').read_text())
artifact=package/'Artifacts/MarmotKit.xcframework'
if artifact.exists(): shutil.rmtree(artifact)
shutil.copytree(mdk/'crates/marmot-uniffi/output/MarmotKit.xcframework',artifact)
swift=(mdk/'crates/marmot-uniffi/output/MarmotKit.swift').read_text()
(package/'Sources/MarmotKit/MarmotKit.swift').write_text('\n'.join(line.rstrip() for line in swift.splitlines())+'\n')
import re
text=(package/'Package.swift').read_text()
text=re.sub(r'let marmotKitLocalPath: String\? = .*', 'let marmotKitLocalPath: String? = "Artifacts/MarmotKit.xcframework"',text)
(package/'Package.swift').write_text(text)
manifest['installation']='local; immutable snapshot required before merge'
manifest['xcode']=subprocess.check_output(['xcodebuild','-version'],text=True).strip().splitlines()
manifest['swift']=subprocess.check_output(['xcrun','swift','--version'],text=True).strip().splitlines()
manifest['apple_sdks']={sdk:subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-version'],text=True).strip() for sdk in ['iphoneos','iphonesimulator']}
manifest['installed_swift_sha256']=hashlib.sha256((package/'Sources/MarmotKit/MarmotKit.swift').read_bytes()).hexdigest()
(package/'LOCAL_BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n')
built=datetime.datetime.now(datetime.timezone.utc).isoformat()
uniffi=re.search(r'uniffi = \{ version = "([^"]+)"', (mdk/'crates/marmot-uniffi/Cargo.toml').read_text()).group(1)
(package/'MARMOT_VERSION').write_text(f'mdk-sha: {sha}\nmdk-branch: master\nmdk-tag: local-{sha}\nbuilt-at: {built}\nfeatures: otlp-export,product-analytics-export\nSee LOCAL_BUILD.json for exact artifact checksums and toolchain.\n')
(package/'Sources/MarmotKit/MarmotKitVersion.swift').write_text(f'''import Foundation

/// Provenance for locally built, unpublished bindings.
public enum MarmotKitVersion {{
    public static let mdkSHA = "{sha}"
    public static let mdkTag = "local-{sha}"
    public static let builtAt = "{built}"
    public static let uniffiVersion = "{uniffi}"
    public static let features = "otlp-export,product-analytics-export"
}}
''')
PY
