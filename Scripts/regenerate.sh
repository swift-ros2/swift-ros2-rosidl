#!/usr/bin/env bash
# Regenerates Sources/<Module>/Generated and Sources/RosidlOracleCorpus/Generated from the
# upstream IDL pinned in idl.lock.
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/fetch-idl.sh
ARGS=()
while IFS= read -r line; do ARGS+=("$line"); done < <(bash Scripts/generator-args.sh)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swift build --product swift-ros2-gen -c release >/dev/null
.build/release/swift-ros2-gen "${ARGS[@]}" --output "$OUT/types" --emit-oracle-samples "$OUT/samples"
for dir in "$OUT"/types/*/; do
  module=$(basename "$dir")
  rm -rf "Sources/$module/Generated"
  mkdir -p "Sources/$module/Generated"
  cp "$dir"*.swift "Sources/$module/Generated/"
done
rm -rf Sources/RosidlOracleCorpus/Generated
mkdir -p Sources/RosidlOracleCorpus/Generated
cp "$OUT"/samples/*.swift Sources/RosidlOracleCorpus/Generated/
echo "regenerated: $(ls "$OUT"/types | tr '\n' ' ')"
