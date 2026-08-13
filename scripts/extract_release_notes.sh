#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-}"
output_path="${2:-}"
changelog_path="${3:-$repo_dir/CHANGELOG.md}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must use X.Y.Z format (got: ${version:-missing})" >&2
    exit 1
fi
if [[ ! -f "$changelog_path" ]]; then
    echo "error: changelog not found: $changelog_path" >&2
    exit 1
fi

section="$({
    awk -v target="$version" '
        $0 == "## [" target "]" {
            found = 1
            next
        }
        found && /^## \[[^]]+\][[:space:]]*$/ {
            exit
        }
        found {
            lines[++count] = $0
        }
        END {
            first = 1
            while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
            last = count
            while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    ' "$changelog_path"
} || true)"

if [[ -z "${section//[[:space:]]/}" ]]; then
    echo "error: CHANGELOG.md has no non-empty section for version $version" >&2
    exit 1
fi

if [[ -n "$output_path" ]]; then
    mkdir -p "$(dirname "$output_path")"
    printf '## 新功能与改进\n\n%s\n' "$section" > "$output_path"
else
    printf '## 新功能与改进\n\n%s\n' "$section"
fi
