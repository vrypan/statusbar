#!/usr/bin/env bash
set -euo pipefail

: "${HOMEBREW_TAP_GITHUB_TOKEN:?HOMEBREW_TAP_GITHUB_TOKEN is required}"

owner="vrypan"
repo="statusbar"
tap_repo="homebrew-tap"
tap_branch="main"
formula_name="statusbar"
commit_name="Panayotis Vryonis"
commit_email="58812+vrypan@users.noreply.github.com"

tag="${1:-${GITHUB_REF_NAME:-}}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "usage: $0 v<version>" >&2
    exit 2
fi
version="${tag#v}"

source_url="https://github.com/${owner}/${repo}/archive/refs/tags/${tag}.tar.gz"
tmpdir="$(mktemp -d)"
trap 'rm -rf -- "$tmpdir"' EXIT

source_archive="${tmpdir}/${repo}-${version}.tar.gz"
curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
    --output "$source_archive" "$source_url"
source_sha256="$(sha256sum "$source_archive" | awk '{print $1}')"

git clone --depth 1 \
    "https://x-access-token:${HOMEBREW_TAP_GITHUB_TOKEN}@github.com/${owner}/${tap_repo}.git" \
    "${tmpdir}/tap"

formula_dir="${tmpdir}/tap/Formula"
formula_path="${formula_dir}/${formula_name}.rb"
mkdir -p "$formula_dir"
sed \
    -e "s/@VERSION@/${version}/g" \
    -e "s/@SOURCE_SHA256@/${source_sha256}/g" \
    .github/homebrew/statusbar.rb.in > "$formula_path"

ruby -c "$formula_path"
git -C "${tmpdir}/tap" config user.name "$commit_name"
git -C "${tmpdir}/tap" config user.email "$commit_email"
git -C "${tmpdir}/tap" add "Formula/${formula_name}.rb"
if git -C "${tmpdir}/tap" diff --cached --quiet; then
    echo "Homebrew formula already up to date."
    exit 0
fi
git -C "${tmpdir}/tap" commit -m "Update ${formula_name} to ${tag}"
git -C "${tmpdir}/tap" push origin "$tap_branch"
