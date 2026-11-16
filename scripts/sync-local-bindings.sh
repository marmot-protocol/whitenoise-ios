#!/usr/bin/env bash
# Build a clean, pinned MDK checkout. Local artifacts are never committed.
# --dev-device-groups builds MDK's experimental device groups (multi-device
# linking) for a controlled test build; the app opens it only with Developer
# Tools → Link Devices on. Never commit or ship its output.
set -euo pipefail
dev_device_groups=0
if [[ "${1:-}" == --dev-device-groups ]]; then
  dev_device_groups=1
  shift
fi
if [[ $# != 2 ]]; then
  echo 'usage: scripts/sync-local-bindings.sh [--dev-device-groups] <mdk-checkout> <full-master-sha>' >&2
  exit 2
fi
local_mdk="$(cd "$1" && pwd)"
source_sha="$2"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$(git -C "$local_mdk" rev-parse HEAD)" == "$source_sha" ]] || { echo 'MDK checkout does not match requested SHA' >&2; exit 1; }
[[ -z "$(git -C "$local_mdk" status --porcelain)" ]] || { echo 'MDK checkout must be clean' >&2; exit 1; }
ios_root="$(cd "$(dirname "$0")/.." && pwd)"
export OTLP_EXPORT=1 PRODUCT_ANALYTICS_EXPORT=1
if [[ "$dev_device_groups" == 1 ]]; then
  output_dir=output-dev-device-groups
  features=otlp-export,product-analytics-export,dev-device-groups
  "$local_mdk/crates/marmot-uniffi/xcframework.sh" --dev-device-groups
else
  output_dir=output
  features=otlp-export,product-analytics-export
  "$local_mdk/crates/marmot-uniffi/xcframework.sh"
fi
[[ "$(git -C "$local_mdk" rev-parse HEAD)" == "$source_sha" && -z "$(git -C "$local_mdk" status --porcelain)" ]] || exit 1
"$local_mdk/crates/marmot-uniffi/validate-ios-artifact.sh" "$local_mdk/crates/marmot-uniffi/$output_dir/MarmotKit.xcframework" 18.0
if [[ "$dev_device_groups" == 0 ]]; then
  # Release packaging reads only the ordinary output; the dev build is never packaged.
  (
    cd "$local_mdk"
    ./crates/marmot-uniffi/package-ios-artifacts.sh "local-$source_sha" "local-$source_sha" "$source_sha" "$ios_root/build/local-marmotkit" "$source_sha"
  )
fi
python3 - "$local_mdk" "$ios_root" "$source_sha" "$output_dir" "$features" <<'PY'
from pathlib import Path
import datetime,hashlib,json,shutil,subprocess,sys
mdk,root,sha,output_dir,features=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],sys.argv[4],sys.argv[5]
output=mdk/'crates/marmot-uniffi'/output_dir
package=root/'Packages/MarmotKit'
manifest_path=root/f'build/local-marmotkit/marmotkit-ios-local-{sha}.manifest.json'
manifest=json.loads(manifest_path.read_text()) if output_dir=='output' else {'source_sha':sha,'features':features}
artifact=package/'Artifacts/MarmotKit.xcframework'
if artifact.exists(): shutil.rmtree(artifact)
shutil.copytree(output/'MarmotKit.xcframework',artifact)
swift=(output/'MarmotKit.swift').read_text()
(package/'Sources/MarmotKit/MarmotKit.swift').write_text('\n'.join(line.rstrip() for line in swift.splitlines())+'\n')
import re
text=(package/'Package.swift').read_text()
text=re.sub(r'let marmotKitLocalPath: String\? = .*', 'let marmotKitLocalPath: String? = "Artifacts/MarmotKit.xcframework"',text)
resources=package/'Sources/MarmotKit/Resources'
resources.mkdir(exist_ok=True)
shutil.copy2(output/'PrivacyInfo.xcprivacy', resources/'PrivacyInfo.xcprivacy')
if 'resources: [.copy("Resources/PrivacyInfo.xcprivacy")]' not in text:
    text=text.replace('path: "Sources/MarmotKit",', 'path: "Sources/MarmotKit",\n            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],')
(package/'Package.swift').write_text(text)
manifest['installation']='local; immutable snapshot required before merge'
manifest['xcode']=subprocess.check_output(['xcodebuild','-version'],text=True).strip().splitlines()
manifest['swift']=subprocess.check_output(['xcrun','swift','--version'],text=True).strip().splitlines()
manifest['apple_sdks']={sdk:subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-version'],text=True).strip() for sdk in ['iphoneos','iphonesimulator']}
manifest['installed_swift_sha256']=hashlib.sha256((package/'Sources/MarmotKit/MarmotKit.swift').read_bytes()).hexdigest()
(package/'LOCAL_BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n')
built=datetime.datetime.now(datetime.timezone.utc).isoformat()
uniffi=re.search(r'^uniffi = (?:\{ version = )?"([^"]+)"', (mdk/'crates/marmot-uniffi/Cargo.toml').read_text(), re.M).group(1)
(package/'MARMOT_VERSION').write_text(f'mdk-sha: {sha}\nmdk-branch: master\nmdk-tag: local-{sha}\nbuilt-at: {built}\nfeatures: {features}\nSee LOCAL_BUILD.json for exact artifact checksums and toolchain.\n')
(package/'Sources/MarmotKit/MarmotKitVersion.swift').write_text(f'''import Foundation

/// Provenance for locally built, unpublished bindings.
public enum MarmotKitVersion {{
    public static let mdkSHA = "{sha}"
    public static let mdkTag = "local-{sha}"
    public static let builtAt = "{built}"
    public static let uniffiVersion = "{uniffi}"
    public static let features = "{features}"
}}
''')
PY
