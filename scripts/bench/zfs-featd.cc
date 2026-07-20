/*
 * OpenZFS-on-OSv feature coverage probe (Phase D).
 *
 * Runs scripted zpool/zfs/zdb sequences against block devices passed through
 * as /dev/vblk0.1, vblk1.1, ...  Each subtest prints "PASS <name>" or
 * "FAIL <name>: <detail>".  Selected by argv[1] (a tier or single test name);
 * "all" runs the lot.
 *
 * Devices: this harness expects the caller to attach enough virtio-blk disks.
 * OSv names partition 1 of disk N as /dev/vblkN.1 (the pool device we use).
 */
extern "C" int osv_run_app(const char *app_path, const char *args[], int args_len);
extern "C" void zfsdev_init();
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static int g_pass = 0, g_fail = 0;

static int run(const char *path, std::vector<std::string> a, bool quiet=false) {
    std::vector<const char*> c;
    for (auto &s : a) c.push_back(s.c_str());
    int r = osv_run_app(path, c.data(), c.size());
    if (!quiet) {
        printf("    $ %s", path);
        for (auto &s : a) printf(" %s", s.c_str());
        printf("  -> %d\n", r);
    }
    return r;
}
static int zpool(std::vector<std::string> a, bool q=false){ a.insert(a.begin(),"zpool"); return run("/zpool.so",a,q);}
static int zfs(std::vector<std::string> a, bool q=false){ a.insert(a.begin(),"zfs"); return run("/zfs.so",a,q);}
static int zdb(std::vector<std::string> a, bool q=false){ a.insert(a.begin(),"zdb"); return run("/zdb.so",a,q);}

static void ok(const char *name){ printf("PASS %s\n", name); g_pass++; }
static void no(const char *name, const char *why){ printf("FAIL %s: %s\n", name, why); g_fail++; }

// write pattern, read back, verify. returns 0 on match.
static int rw_verify(const char *path, unsigned long mb, int flags=0) {
    const size_t BUF = 1024*1024;
    char *w = (char*)malloc(BUF), *r = (char*)malloc(BUF);
    for (size_t i=0;i<BUF;i++) w[i] = (char)((i*7+13)&0xff);
    int fd = open(path, O_CREAT|O_RDWR|O_LARGEFILE|flags, 0644);
    if (fd<0){ free(w);free(r); return -1; }
    for (unsigned long i=0;i<mb;i++) if (write(fd,w,BUF)!=(ssize_t)BUF){ close(fd);free(w);free(r);return -2;}
    fsync(fd);
    lseek(fd,0,SEEK_SET);
    int bad=0;
    for (unsigned long i=0;i<mb;i++){ if(read(fd,r,BUF)!=(ssize_t)BUF){bad=-3;break;} if(memcmp(w,r,BUF)){bad=-4;break;} }
    close(fd); free(w); free(r);
    return bad;
}

static void mkbase(const char *dev, const char *pool, std::vector<std::string> extra_O={}) {
    std::vector<std::string> args = {"create","-f","-o","ashift=12"};
    for (auto &e: extra_O){ args.push_back("-O"); args.push_back(e); }
    args.push_back(pool); args.push_back(dev);
    zpool(args, true);
}

// ---------- Tier 0 ----------
static void t0(const char *dev) {
    const char *P="t0";
    if (zpool({"create","-f","-o","ashift=12","-O","compression=off",P,dev})!=0){ no("t0.create","zpool create failed"); return; }
    ok("t0.pool_create");
    if (zpool({"status",P})==0) ok("t0.status"); else no("t0.status","");
    if (zfs({"create",std::string(P)+"/ds"})==0) ok("t0.dataset_create"); else no("t0.dataset_create","");
    // props
    if (zfs({"set","recordsize=128k",std::string(P)+"/ds"})==0 &&
        zfs({"get","-H","-o","value","recordsize",std::string(P)+"/ds"},true)==0) ok("t0.prop_recordsize"); else no("t0.prop_recordsize","");
    if (zfs({"set","relatime=on",std::string(P)+"/ds"})==0) ok("t0.prop_relatime"); else no("t0.prop_relatime","");
    if (zfs({"set","canmount=on",std::string(P)+"/ds"})==0) ok("t0.prop_canmount"); else no("t0.prop_canmount","");
    // file io + integrity
    int v = rw_verify(("/"+std::string(P)+"/ds/f").c_str(), 64);
    if (v==0) ok("t0.file_rw_integrity"); else { char b[64]; snprintf(b,64,"rw_verify=%d",v); no("t0.file_rw_integrity",b); }
    // compression lz4
    if (zfs({"set","compression=lz4",std::string(P)+"/ds"})==0) ok("t0.compression_lz4"); else no("t0.compression_lz4","");
    if (zfs({"set","compression=off",std::string(P)+"/ds"})==0) ok("t0.compression_off"); else no("t0.compression_off","");
    // checksum
    if (zfs({"set","checksum=fletcher4",std::string(P)+"/ds"})==0) ok("t0.checksum_fletcher4"); else no("t0.checksum_fletcher4","");
    if (zfs({"set","checksum=sha256",std::string(P)+"/ds"})==0) ok("t0.checksum_sha256"); else no("t0.checksum_sha256","");
    // readonly
    if (zfs({"set","readonly=on",std::string(P)+"/ds"})==0) ok("t0.prop_readonly"); else no("t0.prop_readonly","");
    zfs({"set","readonly=off",std::string(P)+"/ds"},true);
    // scrub
    if (zpool({"scrub",P})==0) ok("t0.scrub"); else no("t0.scrub","");
    sleep(2);
    if (zpool({"status",P})==0) ok("t0.scrub_status"); else no("t0.scrub_status","");
    // destroy dataset
    if (zfs({"destroy",std::string(P)+"/ds"})==0) ok("t0.dataset_destroy"); else no("t0.dataset_destroy","");
    // NOTE: skip export (known OSv mutex bug); destroy instead.
    if (zpool({"destroy",P})==0) ok("t0.pool_destroy"); else no("t0.pool_destroy","");
}

int main(int ac, char **av) {
    const char *tier = ac>1 ? av[1] : "t0";
    const char *dev  = ac>2 ? av[2] : "/dev/vblk0";
    printf("=== phase-d probe tier=%s dev=%s ===\n", tier, dev);
    zfsdev_init();
    mkdir("/etc",0755); { int fd=creat("/etc/mnttab",0644); if(fd>=0)close(fd);}

    if (!strcmp(tier,"mounts")) {
        // probe: can we read /proc/mounts?
        FILE *fp = fopen("/proc/mounts","r");
        printf("fopen(/proc/mounts)=%p\n", (void*)fp);
        if (fp){ char line[512]; while(fgets(line,sizeof line,fp)) printf("MOUNT: %s", line); fclose(fp);}
        printf("=== phase-d done: PASS=0 FAIL=0 ===\n");
        return 0;
    }

    if (!strcmp(tier,"t0")||!strcmp(tier,"all")) t0(dev);

    printf("=== phase-d done: PASS=%d FAIL=%d ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
