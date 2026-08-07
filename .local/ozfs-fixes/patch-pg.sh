#!/bin/bash
# Apply the two OSv-environment neuters to the fresh PG source and rebuild the
# postgres backend binary. OSv runs the unikernel app as uid 0 with fixed FS modes.
set -e
SRC=/b/.local/pg18/src

# 1) check_root() in main.c: OSv has no unprivileged user; allow uid 0.
python3 - <<'PY'
p="/b/.local/pg18/src/src/backend/main/main.c"
s=open(p).read()
old="""check_root(const char *progname)
{
#ifndef WIN32
	if (geteuid() == 0)
	{
		write_stderr("\\"root\\" execution of the PostgreSQL server is not permitted.\\n"
"""
new="""check_root(const char *progname)
{
#ifndef WIN32
	/* OSv: unikernel app runs as uid 0, no unprivileged user to drop to. */
	if (0 && geteuid() == 0)
	{
		write_stderr("\\"root\\" execution of the PostgreSQL server is not permitted.\\n"
"""
assert s.count(old)==1, ("main.c neuter: matches", s.count(old))
open(p,"w").write(s.replace(old,new))
print("patched main.c check_root")
PY

# 2) checkDataDir() perm check in miscinit.c: OSv/ZFS report modes PG rejects.
python3 - <<'PY'
p="/b/.local/pg18/src/src/backend/utils/init/miscinit.c"
s=open(p).read()
old="\tif (stat_buf.st_mode & PG_MODE_MASK_GROUP)\n"
new="\t/* OSv: filesystem modes are not Unix-y; suppress the perms check. */\n\tif (0 && (stat_buf.st_mode & PG_MODE_MASK_GROUP))\n"
assert s.count(old)==1, ("miscinit.c neuter: matches", s.count(old))
open(p,"w").write(s.replace(old,new))
print("patched miscinit.c checkDataDir")
PY

# Rebuild the backend + install the new postgres binary.
cd /b/.local/pg18/obj
export CC=musl-gcc
make -j48 LDFLAGS_EX='-pie' -C src/backend >/tmp/pgmake.log 2>&1 || { tail -20 /tmp/pgmake.log; exit 1; }
cp /b/.local/pg18/obj/src/backend/postgres /b/.local/pg18/install/bin/postgres
echo "=== rebuilt postgres ==="
strings /b/.local/pg18/install/bin/postgres | grep -c 'execution of the PostgreSQL server is not permitted' || true
file /b/.local/pg18/install/bin/postgres
