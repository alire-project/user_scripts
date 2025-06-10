#!/bin/bash

# A script that publishes a crate and monitors the PR checks. Once checks pass,
# the PR is marked as ready for review, and a version tag is pushed to the
# repository. Nothing is done in case of failure.
#
# Must be run from the root of the crate being published, which must reside in
# a github repository.

set -o errexit
set -o nounset

trap 'echo "ERROR at line ${LINENO} (code: $?)" >&2' ERR
trap 'echo "Interrupted" >&2 ; exit 1' INT

# Check dependencies

command -v alr >/dev/null 2>&1 || { echo >&2 "alr is required but it's not in PATH. Aborting."; exit 1; }
command -v unbuffer >/dev/null 2>&1 || { echo >&2 "unbuffer (part of expect) is required but it's not in PATH. Aborting."; exit 1; }

# Identify arguments: --force, --skip-build. If given in command line store in vars to pass along to alr at the proper places

force=$([[ " $* " == *" --force "* ]] && echo "--force" || echo "")
skip_build=$([[ " $* " == *" --skip-build "* ]] && echo "--skip-build" || echo "")

# Check necessary credentials

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "GH_TOKEN is not set"
    exit 1
fi

if alr settings --global --get user.github_login 2>&1 | grep -q "not defined"; then
    echo 'GitHub login is not set, please run `alr settings --global --set user.github_login <your login>'
    exit 1
fi

# Identify version, which is in the property "version" in the JSON output of
# alr show
crate=$(alr --format=JSON show | jq -r '.name')
version=$(alr --format=JSON show | jq -r '.version')

echo "Publishing release with version $version..."

logfile=alire/publish.log

# PUBLISH
# Run unbuffered to preserve colors in output
unbuffer alr -n $force publish $skip_build | tee $logfile

# We need to check whether alr failed in the previous command, as the exit code
# is lost in the pipe
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Failed to publish the crate"
    exit 1
fi

# Identify PR number from output
# In python it would be: pr = re.search(r'/pull/(\d+) for details', p.out).group(1)

PR_line=$(cat $logfile | grep 'for details')
PR=$(echo $PR_line | sed 's/.*\/pull\/\([0-9]*\).*/\1/')

echo "PR created for $crate=$version with number: $PR"

# Check periodically until the PR checks succeed or fail

waited=0
backoff=30
timeout=1800
while true; do
    echo -n "Waiting for PR checks to complete"
    for i in $(seq $backoff -1 1); do
        echo -n "."
        sleep 1
    done
    echo

    sleep $backoff
    waited=$((waited+backoff))
    line=$(alr publish --status | grep /$PR)
    if [[ $line == *Checks_Passed* ]]; then
        break
    elif [[ $line == *Checks_Failed* ]]; then
        echo "Checks failed unexpectedly for PR $PR: $line"
        echo Please review manually at: $PR_line
        exit 1
    elif [[ $waited -gt $timeout ]]; then
        echo "Checks not completed after $timeout seconds for PR $PR"
        echo Please review manually at: $PR_line
        exit 1
    fi
done

# At this point the PR checks have passed and we can request a review

echo "Checks passed for PR $PR, requesting review"
alr publish --request-review=$PR

echo "Publication is underway successfully. After manual review your release should be included in the Alire community index."

echo "Pushing version tag to repository now"
git tag -s v$version -m "Release $version"

# Identify remote of current checkout, or fall back to asking the user. If only
# there is only one remote, use that one. Otherwise, ask the user.
if git remote | wc -l | grep -q '^1$'; then
    remote=$(git remote)
else
    echo "Multiple remotes found. Please specify the remote to push the tag to:"
    git remote
    read -p "Remote: " remote
fi

git fetch --tags $remote
if git tag -l | grep -q "^v$version$"; then
    echo "Tag v$version already exists in the repository"
fi
git push $remote v$version
echo "Tag pushed successfully."

echo "All automatic operations completed."
