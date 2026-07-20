#!/bin/bash

if [ $# -lt 1 ]; then
    echo "Usage: $0 <official-repo-url> [your-username]"
    echo "Example: $0 https://github.com/torvalds/linux"
    echo "Example: $0 https://github.com/torvalds/linux other-username"
    exit 1
fi

USERNAME="${FORK_USERNAME:-}"
if [ $# -eq 2 ]; then
    USERNAME=$2
fi
if [ -z "$USERNAME" ]; then
    echo "No username set. Pass it as the 2nd argument or export FORK_USERNAME=<you>."
    exit 1
fi

OFFICIAL_REPO=$1

REPO_NAME=$(basename "$OFFICIAL_REPO" | sed 's/.git$//')
OFFICIAL_OWNER=$(basename $(dirname "$OFFICIAL_REPO"))

PLATFORM=$(echo "$OFFICIAL_REPO" | cut -d'/' -f3)
FORK_URL="git@${PLATFORM}:${USERNAME}/${REPO_NAME}.git"
# or 'https://' instead of git@


echo "Cloning fork from: $FORK_URL"
git clone "$FORK_URL"

cd "$REPO_NAME" || exit 1

echo "Adding upstream remote: $OFFICIAL_REPO"
git remote add upstream "$OFFICIAL_REPO"

echo ""
echo "Setup complete!!!"
echo "Remotes:"
git remote -v
