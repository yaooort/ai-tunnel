#!/bin/sh
# Compatibility entry point; deployment options are shared with the portable installer.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec sh "$source_dir/install.sh" --source-dir "$source_dir" "$@"
