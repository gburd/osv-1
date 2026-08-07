# Audit Agent 4: fs/block/storage (e80738b6) - COMPLETE
SYSTEMIC: release build = -DNDEBUG -> ALL assert() in storage path COMPILED OUT. Any bounds-check-as-assert = zero protection (affects NVMe cid, ROFS readlink, NVMe/virtio submit).
## CONFIRMED (crafted-image)
1. CRITICAL (CVSS~8.4): ext4 ext_readlink heap overflow. ext_vnops.cc:1808-1817. fsize=ext4_inode_get_size (attacker u64, unbounded) -> malloc(block_size=4096) then ext_internal_read(...,size=fsize) writes ~fsize into 4KB buf. Crafted symlink inode i_size=1MB -> readlink()/traversal -> heap corruption/RCE. Also uio_offset>fsize underflow. FIX: clamp read to min(fsize,block_size), reject fsize>block_size, guard offset>=fsize. (in master AND ext4 worktree)
2. HIGH (CVSS~7.0): map_read_cached_page frees BORROWED page (core/pagecache.cc:363-376, MY commit ed4bee83 on pr/pagecache). ROFS vop_cache passes page INSIDE a file_cache_segment (not alloc_page); dup-key branch memory::free_page()s it -> double-free when ~file_cache_segment frees. Reachable w/o malicious image: concurrent read-fault + readahead prefetch_one_page TOCTOU on same (dev,ino,off). Cache on by default. NOTE: ZFS slow path passes owned page (free correct); ZFS fast path uses separate osv_pagecache_map_arc_page (releases dbuf). openzfs-audit worktree LEAKS instead (diverges). FIX: don't free in map_read_cached_page (match empty dtor) / ownership flag.
3. HIGH (CVSS~7.5): ROFS mount trusts all superblock counts/sizes (rofs_vfsops.cc:110-160, rofs_common.cc:59-83). directory_entries_count/inodes_count*sizeof overflow -> small alloc; entry loop walks data_ptr past buf (OOB); rofs_read_blocks no device->size check -> arbitrary block read. FIX: checked mult, bound counts vs buf+device size.
4. HIGH (CVSS~7.1): ROFS runtime OOB table indexing (rofs_vnops.cc readdir/lookup/readlink/read). data_offset/dir_children_count/inode_no/file_size unvalidated from image; d_ino=0 -> inodes+(uint)-1 OOB; readlink assert compiled out -> OOB ptr deref. FIX: validate indices vs table sizes.
5. HIGH (CVSS~7.0, rev0 image): ext4 ext_readdir d_name[256] overflow. ext_vnops.cc:637-638. name_len up to block_size-8 (~4088) on rev0 minor<5 (name_length_high) memcpy into 256B d_name. FIX: memcpy min(name_len, 255).
6. HIGH (CVSS~6.8): lwext4 extent header max/entries not bounded to block capacity (ext4_extent.c:730-773). find_ext4_extent_tail + binsearch OOB read ~64KB past inode. Upstream lwext4 bug reachable via ext mount. FIX: port ext4_valid_extent_entries.
## CONFIRMED (malicious backend)
7. HIGH (CVSS~7.4): virtio used-ring elem._id unvalidated (virtio-vring.cc:257-261). _cookie[elem._id] OOB read+write, device-controlled id. FIX: if(elem._id>=_num) drop.
8. HIGH (CVSS~7.4): NVMe completion cid unvalidated (nvme-queue.cc:345-346). cid/_qsize>=4 -> _pending_bios OOB (only 4 rows); release assert gone. FIX: bound cid_to_row<max_pending_levels + null-check.
## LOW
9. namei_follow_link 1-byte OOB write when symlink fills PATH_MAX (vfs_lookup.cc:72-75). FIX: read_link(PATH_MAX-1).
## DEF-IN-DEPTH: no bio_offset+bcount<=device->size guard in ext_vfsops blockdev / virtio-blk make_request. Add one bio-layer bound.
## CLEAN: ext4 DEEP read-ahead ring (bounded, drained teardown), VFS symlink loop (MAXSYMLINKS), virtio-blk mq index. MINOR: ext4 dir rec_len==0 -> readdir loop/hang (add rec_len<12 guard).
## PRIORITY: #1 (mountable RCE) + #2 (my pagecache double-free regression, no image needed).

## CORRECTION (parent verified): Finding #2 is NOT in merged/shipped code.
Agent audited the STALE pr/pagecache worktree (this main checkout, pre-#1398-merge-fix). MERGED master has the FIXED version: `bool map_read_cached_page` returns false + does NOT free the borrowed page (ROFS ignores return). This is exactly the ROFS-crash fix from the earlier wkozaczuk report. So #2 = already-fixed, only in the stale local worktree. NOT a live vuln. (Main worktree is stale - should resync to master.)
