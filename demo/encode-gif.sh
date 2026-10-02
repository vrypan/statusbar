#!/bin/sh
# Encode VHS frames as a looping GIF beside the directory, at half size/25 fps.
# Usage: demo/encode-gif.sh demo/push-frames/ [padding-pixels]
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
	echo "usage: $0 FRAMES_DIRECTORY [PADDING_PIXELS]" >&2
	exit 2
fi

frames=${1%/}
out="$frames.gif"
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

# Overlay the cursor, reduce size and frame rate, then build a shared palette.
# VHS raw frames omit padding; add it in output pixels after scaling.
ffmpeg -y -v error \
	-framerate 50 -i "$frames/frame-text-%05d.png" \
	-framerate 50 -i "$frames/frame-cursor-%05d.png" \
	-filter_complex "[0][1]overlay,fps=25,scale=iw/2:-1:flags=lanczos,pad=iw+2*$padding:ih+2*$padding:$padding:$padding:black,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer" \
	-loop 0 "$out"

printf '%s\n' "$out"
