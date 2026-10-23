#!/bin/zsh
# Rebuild the macOS AppIcon variants from the selected, alpha-preserving source.
set -euo pipefail
project_dir="${0:A:h:h}"
icon_source="$project_dir/Design/AppIcon-Source.png"
asset_dir="$project_dir/Waifu2x/Resources/Assets.xcassets/AppIcon.appiconset"
[[ -f "$icon_source" ]] || { print -u2 "Missing icon source: $icon_source"; exit 1; }
for specification in \
    'icon-16@1x.png:16' 'icon-16@2x.png:32' \
    'icon-32@1x.png:32' 'icon-32@2x.png:64' \
    'icon-128@1x.png:128' 'icon-128@2x.png:256' \
    'icon-256@1x.png:256' 'icon-256@2x.png:512' \
    'icon-512@1x.png:512' 'icon-512@2x.png:1024'; do
    filename="${specification%%:*}"
    edge="${specification##*:}"
    /usr/bin/sips -z "$edge" "$edge" "$icon_source" --out "$asset_dir/$filename" >/dev/null
done
print 'Updated all 10 macOS AppIcon assets.'
