#!/bin/bash
# Pull terminal-system/ changes from the syslinuxos-packages monorepo
# (where day-to-day fixes are made) into this standalone repo, preserving
# per-commit history via git subtree.
#
# Usage: scripts/sync-from-monorepo.sh [path-to-syslinuxos-packages]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO="${1:-/home/edmond/Nextcloud/Claude/syslinuxos-packages}"
BRANCH="sync-terminal-system"

cd "$MONOREPO"
git subtree split --prefix=terminal-system -b "$BRANCH"
cd "$HERE"
git fetch "$MONOREPO" "$BRANCH"
git subtree pull --prefix=. "$MONOREPO" "$BRANCH" -m "sync: pull from syslinuxos-packages"
cd "$MONOREPO"
git branch -D "$BRANCH"

echo "Synced. Review the result, then: git push origin main"
