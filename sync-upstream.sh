#!/bin/bash
set -e

git fetch upstream

UPDATES=$(git log HEAD..upstream/main --oneline)

if [ -z "$UPDATES" ]; then
    echo "Already up to date with upstream."
    exit 0
fi

echo "Upstream has updates:"
echo "$UPDATES"
echo ""
read -rp "Sync? [y/N] " response

if [[ "$response" =~ ^[Yy]$ ]]; then
    git rebase upstream/main
    echo "Done."
else
    echo "Aborted."
fi
