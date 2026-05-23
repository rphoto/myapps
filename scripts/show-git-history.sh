#!/bin/bash
cd /Users/rwright/Documents/git-repo-2025/myapps/myapps

{
  echo "=== snapshot $(date) ==="
  echo "HEAD: $(git rev-parse --short HEAD)"
  echo ""
  echo "=== .git on disk ==="
  du -sh .git
  git count-objects -vH
  echo ""
  echo "=== release zips on disk ==="
  find docs -path '*/releases/*.zip' -type f | sort
  echo "count: $(find docs -path '*/releases/*.zip' -type f | wc -l | tr -d ' ')"
  echo ""
  echo "=== release zips in git history ==="
  git log --all --pretty=format: --name-only \
    | grep -E '^docs/.*/releases/[^/]+\.zip$' \
    | sort -u
  echo "count: $(git log --all --pretty=format: --name-only \
    | grep -E '^docs/.*/releases/[^/]+\.zip$' \
    | sort -u | wc -l | tr -d ' ')"
  echo ""
  echo "=== zip blob weight in history ==="
  git rev-list --objects --all \
    | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
    | awk '/^blob/ && $4 ~ /\/releases\/.*\.zip$/ {sum+=$3; n++} END {printf "%d blobs, %.1f MB\n", n, sum/1024/1024}'
} | tee ~/myapps-before.txt
