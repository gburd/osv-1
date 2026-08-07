PRMAINT8 bundles - re-sign (ED25519 -> G) + push (Greg only; floki has no push creds)

1 bundle this sweep:

feat-fork-execed-comment.bundle
  PR:      #1455 (fork base, MERGEABLE, rebased on master 95f478cb7)
  branch:  wip/feat-fork
  base:    5e0fabb41  (current gh-fork tip - fast-forward, NO force needed)
  new tip: fa0b8541b
  change:  1 commit, comment-only (libc/process/fork.cc): documents why
           child_state::execed_app is retained (fulfills the reply promised
           to the copilot review thread). No logic change, no compile needed.

Re-sign + push (fast-forward, branch-name form):
  cd /tmp/ff && git clone ... # or in a worktree at the branch
  git fetch <bundle>          # or: git bundle unbundle feat-fork-execed-comment.bundle
  git cherry-pick / reset to fa0b8541b, re-sign with G, then:
  git push gh-fork HEAD:wip/feat-fork      # plain fast-forward (5e0fabb41 -> fa0b8541b)

  (No --force-with-lease needed: fa0b8541b descends from the current remote tip.)

After push, #1455 goes ahead=4/behind=0, still MERGEABLE. Nothing else pending.
