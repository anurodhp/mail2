#!/bin/bash
# Renders the Lucide SVGs (ISC, icons/LICENSE-lucide.txt) in icons/src into the TIFFs Mail2 draws (every
# GNUstep reads TIFF): toolbar glyphs in normal/disabled colors, sidebar mailbox glyphs in gray and in white
# (for the selected row), and the application icon (tools/make_icon.m). The outputs are committed
# (icons/*.tiff), so the cross build needs none of this; it runs on the macOS host only (AppKit rasterises,
# sips converts to TIFF). Same pipeline as Milan's tools/make_icons.sh.
#   Usage: tools/make_icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
clang -fobjc-arc -framework AppKit -o "$T/svg2png" tools/svg2png.m
clang -fobjc-arc -framework AppKit -o "$T/make_icon" tools/make_icon.m

# render <out-name> <svg> <pixels> <stroke> <stroke-width>
render() {
    local out="$1" src="icons/src/$2.svg" px="$3" col="$4" sw="$5"
    sed -e "s/stroke=\"currentColor\"/stroke=\"$col\"/" -e "s/stroke-width=\"2\"/stroke-width=\"$sw\"/" "$src" > "$T/in.svg"
    "$T/svg2png" "$T/in.svg" "$T/out.png" "$px"
    sips -s format tiff "$T/out.png" --out "icons/$out.tiff" > /dev/null
}

# toolbar glyphs, 20 px (name:lucide-name)
for pair in getmail:refresh-cw compose:square-pen reply:reply replyall:reply-all forward:forward \
            archive:archive delete:trash-2 flag:flag; do
    n="${pair%%:*}"; s="${pair#*:}"
    render "tb-$n-normal"   "$s" 20 "#4a4a4a" 2
    render "tb-$n-disabled" "$s" 20 "#b4b4b4" 2
done
# sidebar glyphs, 16 px: the accent blue, and white on the selected row
for pair in inbox:inbox drafts:file-pen sent:send archive:archive junk:octagon-alert trash:trash-2 \
            folder:folder attachment:paperclip; do
    n="${pair%%:*}"; s="${pair#*:}"
    render "sb-$n"     "$s" 16 "#2f7fd8" 2
    render "sb-$n-sel" "$s" 16 "#ffffff" 2
done
# the application icon
"$T/make_icon" icons/Mail2.png
sips -s format tiff icons/Mail2.png --out icons/Mail2.tiff > /dev/null
