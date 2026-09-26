#!/bin/sh
# Encode a VHS frames directory as an H.264 MP4 beside the directory.
# Usage: demo/encode.sh demo/push-frames/ [padding-pixels]
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
	echo "usage: $0 FRAMES_DIRECTORY [PADDING_PIXELS]" >&2
	exit 2
fi

frames=${1%/}
out="$frames.mp4"
padding=${2:-40}

case $padding in
	*[!0-9]*|'')
		echo "padding must be a non-negative number of pixels" >&2
		exit 2
		;;
esac

if [ ! -f "$frames/frame-text-00001.png" ] || [ ! -f "$frames/frame-cursor-00001.png" ]; then
	echo "missing VHS text or cursor frames in $frames" >&2
	exit 1
fi

# VHS raw frames omit its Padding and Margin settings. Add space around the
# overlaid text and cursor here, then use tests/encode.sh's H.264 settings.
ffmpeg -y -v error \
	-framerate 50 -i "$frames/frame-text-%05d.png" \
	-framerate 50 -i "$frames/frame-cursor-%05d.png" \
	-filter_complex "[0][1]overlay,scale=trunc(iw/2)*2:trunc(ih/2)*2,pad=iw+2*$padding:ih+2*$padding:$padding:$padding:black" \
	-c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p \
	-movflags +faststart "$out"

printf '%s\n' "$out"
