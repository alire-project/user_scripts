#!/bin/bash

# Prepare several manifests for simultanous publishing. This is convenient when
# the release being published depend on each other, thus saving the wait for
# dependencies to be merged before publishing the next one.

# Manifests are prepared in a clone of the community index made in the current
# directory. The script can be run from anywhere where the index can be cloned
# as a subdirectory.

# The script takes as arguments the paths to the root of the crates to be
# published (not necessarily monorepos or in the same repository).

set -o errexit
set -o nounset

trap 'echo "ERROR at line ${LINENO} (code: $?)" >&2' ERR
trap 'echo "Interrupted" >&2 ; exit 1' INT

# BEGIN

# Check if we have at least one path argument
if [ $# -eq 0 ]; then
    echo "Error: At least one crate path must be provided." >&2
    echo "Usage: $0 <crate_path1> [<crate_path2> ...]" >&2
    exit 1
fi

# Start by cloning the community index
INDEX_REPO="https://github.com/alire-project/alire-index.git"
INDEX_DIR="$PWD/alire-index"

if [ ! -d "$INDEX_DIR" ]; then
    echo "Cloning community index..."
    git clone "$INDEX_REPO" "$INDEX_DIR"
else
    echo "Index repository already exists. Using existing clone."
    # Identify default branch using git remote show origin
    DEFAULT_BRANCH=$(git --git-dir="$INDEX_DIR/.git" remote show origin | grep "HEAD branch" | cut -d':' -f2 | xargs)
    echo "Default branch: $DEFAULT_BRANCH"
    # Make sure it's up to date
    (cd "$INDEX_DIR" && git checkout $DEFAULT_BRANCH && git pull)
fi

# Store crate milestones for branch name
MILESTONES=""

# Check that all received arguments are existing directories with valid crates
for CRATE_PATH in "$@"; do
    if [ ! -d "$CRATE_PATH" ]; then
        echo "Error: '$CRATE_PATH' is not a directory." >&2
        exit 1
    fi

    # Enter the crate directory
    pushd "$CRATE_PATH" > /dev/null

    # Check if it's a valid crate
    if ! CRATE_INFO=$(alr show 2>/dev/null | head -n 1); then
        echo "Error: '$CRATE_PATH' does not appear to be a valid crate." >&2
        popd > /dev/null
        exit 1
    fi

    echo "Found valid crate: $CRATE_INFO"

    # Extract crate name and milestone for branch naming
    CRATE_MILESTONE=$(echo "$CRATE_INFO" | cut -d':' -f1)
    MILESTONES+=" ${CRATE_MILESTONE}"

    popd > /dev/null
done

# Trim leading space in MILESTONES
MILESTONES="${MILESTONES#" "}"

# Create a new branch in the index
pushd "$INDEX_DIR" > /dev/null

# Replace spaces with underscores in the MILESTONES variable
BRANCH_NAME=publish-${MILESTONES// /-}
echo "Creating branch: $BRANCH_NAME"
git checkout -B "$BRANCH_NAME"

popd > /dev/null

# Process each crate
for CRATE_PATH in "$@"; do
    pushd "$CRATE_PATH" > /dev/null

    echo "Publishing crate in $CRATE_PATH..."

    # Get crate name using a JSON query
    CRATE_NAME=$(alr --format show | jq -r .name)
    CRATE_VERSION=$(alr --format show | jq -r .version)

    # Run the publish command
    alr -n -q publish --skip-build --skip-submit

    # Find the generated manifest
    MANIFEST="alire/releases/${CRATE_NAME}-${CRATE_VERSION}.toml"

    if [ -z "$MANIFEST" ]; then
        echo "Error: No manifest found after publishing." >&2
        popd > /dev/null
        exit 1
    fi

    echo "Generated manifest: $MANIFEST"

    # Determine the destination in the index
    # First two letters of crate name form the first directory level
    PREFIX="${CRATE_NAME:0:2}"

    # Find the 'aa' directory to locate where classification folders are
    AA_DIR=$(find "$INDEX_DIR" -type d -name "aa" | head -n 1)
    if [ -z "$AA_DIR" ]; then
        echo "Error: Could not find 'aa' directory in the index." >&2
        popd > /dev/null
        exit 1
    fi

    # Classification folders are siblings to 'aa'
    CLASS_DIR=$(dirname "$AA_DIR")
    INDEX_DEST="$CLASS_DIR/$PREFIX/$CRATE_NAME"

    echo "Destination in index: $INDEX_DEST"

    # Ensure destination directory exists
    mkdir -p "$INDEX_DEST"

    # Copy the manifest
    cp "$MANIFEST" "$INDEX_DEST/"
    echo "Copied manifest to $INDEX_DEST/"

    popd > /dev/null
done

# Check status in the index
pushd "$INDEX_DIR" > /dev/null

echo "Checking git status in index..."
git add .
git status

# Commit all changes
echo "Committing changes to branch $BRANCH_NAME..."
git add -A
# Prepare commit message: it should be the milestones separated by commas, with
# "=" replaced by one space
COMMIT_MESSAGE=$(echo "$MILESTONES" | tr ' ' ', ' | tr '=' ' ')
git commit -m "${COMMIT_MESSAGE}"

# Ask user for GitHub permissions
read -p "Would you like to interact with GitHub to push these changes (y/n): " GITHUB_PERMISSION

if [[ "$GITHUB_PERMISSION" =~ ^[Yy] ]]; then
    # Check if user has a fork
    GH_USER=$(gh api user | jq -r .login)

    if [ -z "$GH_USER" ]; then
        echo "Error: Unable to get GitHub username. Please ensure 'gh' is authenticated." >&2
        exit 1
    fi

    # Check if fork exists
    if ! gh repo view "$GH_USER/alire-index" &>/dev/null; then
        echo "You don't have a fork of the alire-index. Creating one..."
        gh repo fork alire-project/alire-index --clone=false
    fi

    # Add user's fork as a remote
    REMOTE_NAME="$GH_USER"
    git remote add "$REMOTE_NAME" "https://github.com/$GH_USER/alire-index.git" 2>/dev/null || true

    # Push to user's fork
    echo "Pushing changes to your fork..."
    git push -u "$REMOTE_NAME" "$BRANCH_NAME"

    # Ask to create PR
    read -p "Would you like to create a PR to the community index? (y/n): " PR_PERMISSION

    if [[ "$PR_PERMISSION" =~ ^[Yy] ]]; then
        echo "Creating pull request..."
        PR_URL=$(gh pr create --repo alire-project/alire-index --head "$GH_USER:$BRANCH_NAME" --title "Publish: $MILESTONES" --body "Adding manifests for: $MILESTONES")

        echo "Pull request created: $PR_URL"
        echo "Please check that everything is in order."
    fi
fi

popd > /dev/null

echo "All done! Manifests have been prepared in the alire-index directory."

# END
