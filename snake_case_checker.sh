#!/bin/bash

# Function to check if a file name follows snake_case
check_snake_case() {
  local file="$1"
  if [[ ! "$file" =~ ^[a-z0-9_]+(\.[a-z0-9_]+)*$ ]]; then
    echo "❌ File '$file' does not follow snake_case naming convention."
    return 1
  fi
  return 0
}

# Simulate the branches or commits to compare
# Replace these with actual branch names or commit SHAs for testing
TARGET_BRANCH="main"  # Replace with the target branch
CURRENT_BRANCH="voda-Programme-MND-email"  # Replace with the current branch

# Fetch the latest changes for both branches (optional if already fetched)
git fetch origin "$TARGET_BRANCH"
git fetch origin "$CURRENT_BRANCH"

# Get the list of changed or created files between the two branches
CHANGED_FILES=$(git diff --name-only --diff-filter=ACR origin/"$TARGET_BRANCH" origin/"$CURRENT_BRANCH")

# Check if there are any changed files
if [[ -z "$CHANGED_FILES" ]]; then
  echo "✅ No files were changed or created."
  exit 0
fi

echo "🔍 Checking the following files for snake_case naming convention:"
echo "$CHANGED_FILES"

# Initialise a flag to track if any file fails the check
ALL_FILES_VALID=true

# Loop through each changed file and check its naming convention
for FILE in $CHANGED_FILES; do
  if ! check_snake_case "$FILE"; then
    ALL_FILES_VALID=false
  fi
done

# Exit with an appropriate status
if [[ "$ALL_FILES_VALID" == true ]]; then
  echo "✅ All file names follow snake_case naming convention."
  exit 0
else
  echo "❌ Some file names do not follow snake_case naming convention."
  exit 1
fi
