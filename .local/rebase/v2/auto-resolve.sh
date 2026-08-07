#!/bin/bash
# Auto-resolve common conflict patterns and continue the rebase.
# Pattern A: external/openzfs submodule clash → force final f71d0e69 sha
# Pattern B: deleted-by-us tests/tst-* file → keep delete (rm -f)
# Pattern C: deleted-by-us bsd/sys/cddl/* file → keep delete
# Pattern D: deleted-by-us external/openzfs file → keep delete (it's a submodule)
# Pattern E: modified-by-them modules/{tests,zfs-tools}/{Makefile,usr.manifest} → take theirs

while true; do
  # Set submodule to final sha
  git update-index --cacheinfo 160000,f71d0e6929beb421c6baf356817d1c79c7f801b3,external/openzfs 2>/dev/null

  # Auto-resolve unmerged tests/tst-* files: rm if "deleted by us"
  while read -r line; do
    case "$line" in
      *"deleted by us:   tests/"*)
        f=$(echo "$line" | awk '{print $NF}')
        git rm -f "$f" 2>/dev/null
        ;;
      *"deleted by us:   bsd/sys/cddl/"*)
        f=$(echo "$line" | awk '{print $NF}')
        git rm -f "$f" 2>/dev/null
        ;;
      *"deleted by us:   external/openzfs"*)
        f=$(echo "$line" | awk '{print $NF}')
        git rm -f "$f" 2>/dev/null
        ;;
    esac
  done < <(git status --porcelain | grep -E "^DU |^UD ")

  # For both-modified Makefile/manifest, take theirs (the incoming changes)
  for f in modules/tests/Makefile modules/zfs-tools/usr.manifest; do
    if git status --porcelain | grep -q "^UU $f"; then
      git checkout --theirs -- "$f"
      git add "$f"
    fi
  done

  out=$(GIT_EDITOR=true git rebase --continue 2>&1)
  if echo "$out" | grep -q "Successfully rebased"; then
    echo "DONE"
    break
  fi
  if echo "$out" | grep -q "could not apply"; then
    if echo "$out" | grep -qE "submodule.*external/openzfs|Failed to merge submodule"; then
      continue
    fi
    # Check if conflicts are auto-resolvable
    has_unresolvable=0
    while read -r line; do
      case "$line" in
        *"deleted by us:   tests/"*) ;;
        *"deleted by us:   bsd/sys/cddl/"*) ;;
        *"deleted by us:   external/openzfs"*) ;;
        *"both modified:   modules/tests/Makefile"*) ;;
        *"both modified:   modules/zfs-tools/usr.manifest"*) ;;
        *)
          has_unresolvable=1
          ;;
      esac
    done < <(git status --porcelain | grep -E "^DU |^UD |^UU ")
    if [ $has_unresolvable -eq 1 ]; then
      echo "UNRESOLVABLE-CONFLICT"
      git status --porcelain | grep -E "^DU |^UD |^UU "
      break
    fi
    # else loop again
    continue
  fi
  break
done
