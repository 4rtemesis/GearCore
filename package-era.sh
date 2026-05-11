#!/usr/bin/env bash

set -euo pipefail

addon_name="RustcoreEra"
version="${1:-$(date +%Y%m%d-%H%M%S)}"
dist_dir="dist"
source_dir="${addon_name}"
stage_dir="${dist_dir}/${addon_name}"
zip_path="${dist_dir}/${addon_name}-${version}.zip"

mkdir -p "${dist_dir}"
rm -rf "${stage_dir}"
mkdir -p "${stage_dir}"

files=(
  "RustcoreEra.toc"
  "Rustcore.lua"
  "RustcoreBroadcast.lua"
  "RustcoreTheme.lua"
  "RustcoreOptions.lua"
  "RustcoreUI.lua"
  "RCicon.png"
  "Breaksound.flac"
  "Spinsound.wav"
)

for file in "${files[@]}"; do
  cp "${source_dir}/${file}" "${stage_dir}/"
done

cp -r "${source_dir}/UI" "${stage_dir}/"

rm -f "${zip_path}"

if command -v zip >/dev/null 2>&1; then
  (
    cd "${dist_dir}"
    zip -r "$(basename "${zip_path}")" "${addon_name}"
  )
elif command -v python3 >/dev/null 2>&1; then
  python3 -c '
import os
import sys
import zipfile

source_dir = sys.argv[1]
zip_path = sys.argv[2]

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(source_dir):
        for name in files:
            full_path = os.path.join(root, name)
            arcname = os.path.relpath(full_path, os.path.dirname(source_dir))
            zf.write(full_path, arcname)
' "${stage_dir}" "${zip_path}"
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command \
    "Compress-Archive -Path '${stage_dir}' -DestinationPath '${zip_path}' -Force" \
    >/dev/null
else
  echo "No supported archive tool found. Install 'zip' or run from Windows with PowerShell available." >&2
  exit 1
fi

echo "Created ${zip_path}"
