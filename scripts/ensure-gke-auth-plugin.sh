#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$repo_root/.tools/gke-auth/bin"
plugin="$plugin_dir/gke-gcloud-auth-plugin.exe"
archive_dir="$repo_root/.tools/gke-auth"
archive="$archive_dir/gke-gcloud-auth-plugin-0.5.18-windows-x86_64.tar.gz"
archive_url="https://dl.google.com/dl/cloudsdk/channels/rapid/components/google-cloud-sdk-gke-gcloud-auth-plugin-windows-x86_64-20260717053915.tar.gz"
archive_sha256="8c3a0b59797a031611dd6502313b2aa86886a26a827102ae086dab327089c61b"

if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  gke-gcloud-auth-plugin --version >/dev/null
  exit 0
fi

case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *)
    printf 'Install the official gke-gcloud-auth-plugin for this platform.\n' >&2
    exit 1
    ;;
esac

for command_name in curl sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command not found while installing the GKE auth plugin: %s\n' \
      "$command_name" >&2
    exit 1
  }
done

mkdir -p "$archive_dir" "$plugin_dir"

archive_valid=0
if [[ -f "$archive" ]]; then
  actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual_sha256" == "$archive_sha256" ]] && archive_valid=1
fi

if ((archive_valid == 0)); then
  partial_archive="${archive}.partial"
  rm -f -- "$partial_archive"
  curl --fail --location --silent --show-error \
    "$archive_url" \
    --output "$partial_archive"
  actual_sha256="$(sha256sum "$partial_archive" | awk '{print $1}')"
  [[ "$actual_sha256" == "$archive_sha256" ]] || {
    rm -f -- "$partial_archive"
    printf 'The downloaded GKE auth plugin archive failed its pinned SHA-256 check.\n' >&2
    exit 1
  }
  mv -f -- "$partial_archive" "$archive"
fi

tar -xzf "$archive" -C "$archive_dir" bin/gke-gcloud-auth-plugin.exe
[[ -x "$plugin" ]] || {
  printf 'The GKE auth plugin archive did not produce an executable.\n' >&2
  exit 1
}
"$plugin" --version >/dev/null
printf 'Installed pinned GKE auth plugin 0.5.18 under ignored .tools/.\n'
