#!/bin/sh
# Downloads the official YAML test suite into DIR (default: conformance-suite/
# in the repository, ignored by git) so that
# `zig build conformance -Dsuite=DIR` can run it. Needs git.
# The suite has its own licence (MIT, see the suite's repository) and is not
# part of this one.
set -eu

url=https://github.com/yaml/yaml-test-suite
# The commit of the data-2022-01-17 release, which the results in ai/SPEC.md
# were measured with. Asking for the commit rather than the tag pins the
# content: a moved tag cannot change what is run.
commit=6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f

root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-$root/conformance-suite}

# Nothing that is already there is overwritten or deleted. Only an empty
# directory, or one left by an interrupted run of this script, is filled.
if [ -d "$dir/.git" ] && have=$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}'); then
    if [ "$have" != "$commit" ]; then
        echo "$dir: a checkout of another commit ($have); remove it or name another directory" >&2
        exit 1
    fi
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        echo "$dir: the suite has local changes; remove it or name another directory" >&2
        exit 1
    fi
    echo "already there: $dir"
else
    if [ ! -d "$dir/.git" ] && [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
        echo "$dir: not empty and not made by this script" >&2
        exit 1
    fi
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    echo "downloaded to $dir"
fi

echo "run: zig build conformance -Dsuite=$dir"
