#!/bin/bash
# Sequence editor for git rebase --interactive.
# Reads the original TODO ($1) and overwrites it with our planned sequence.
set -euo pipefail
cat > "$1" <<'EOF'
pick b234155f
pick dd8f9751
pick 981d5308
pick 3d9b3950
pick 2acf2c58
pick 124956b6
pick 77c3fb2b
pick 2894cffc
pick 8c77d780
pick 31c6a8fd
pick 688183a1
pick 953c4a96
pick f8a0f5ce
pick a1ca7318
pick fb1703ea
pick 4363efda
pick e3a328a1
pick 8f9c9502
pick 08ed8429
pick 8b8a1490
pick 9e0f9978
pick 1de0a1af
pick a3531749
pick f80260d5
pick 375598d2
pick 4bd2b109
pick ea4f3d51
pick 95acf03e
pick 746d9fa1
pick 65e2a289
pick 6059dce9
pick 55523197
pick e0e5f314
pick 7d2dc7f1
pick f72eff82
pick 5270897a
pick 3fc44018
pick 4b7f8414
pick 5720dc7c
pick fc08b26d
pick 2d2858a4
pick c275ee86
pick 6d0d7d8c
pick 3d16b39a
pick 5fde3f3b
pick d080d717
pick 69d1788f
pick 36694b7f
pick e1b9198f
pick ab371dd0
pick 9d9e381c
pick f9d097aa
pick 0293d6d4
pick 8016f1e9
pick 54796e1a
pick 8ab7103d
pick c8c5c255
pick 99ebc239
pick 0d41fb93
pick 83d010ee
pick b08106ad
exec git cherry-pick -n 04ac529f && git cherry-pick -n d0f9c98b -- tests/tst-zfs-multirec.cc && (cd external/openzfs && git fetch && git checkout f71d0e6929beb421c6baf356817d1c79c7f801b3) && git add external/openzfs && git commit --amend --no-edit
pick b4a4f692
pick 79697a0f
pick 043c2f54
pick 1bcfc18a
pick 3157a203
pick dbc961c8
pick f221e924
fixup 732b778e
exec git cherry-pick -n 7e664831 -- drivers/ && git commit --amend --no-edit
fixup 8e79e283
fixup 2313071c
fixup bd304b28
fixup beb809c7
exec git cherry-pick -n d0f9c98b -- tests/tst-crucible-zfs.cc && git commit --amend --no-edit
fixup f8f7ff0e
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/crucible-msg.txt
EOF
