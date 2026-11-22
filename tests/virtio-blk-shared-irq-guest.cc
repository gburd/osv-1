#include <pthread.h>
#include <sched.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>

static void* read_queue(void* arg)
{
    long cpu = reinterpret_cast<long>(arg);
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    int rc = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    if (rc) { std::printf("FAIL affinity cpu=%ld rc=%d\n", cpu, rc); return (void*)1; }
    void* buf = nullptr;
    if (posix_memalign(&buf, 4096, 4096)) return (void*)1;
    int fd = open("/dev/vblk0", O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); free(buf); return (void*)1; }
    std::printf("READ cpu=%ld actual=%d\n", cpu, sched_getcpu());
    for (int n = 0; n < 32; ++n) {
        if (pread(fd, buf, 4096, 0) != 4096) {
            perror("pread"); close(fd); free(buf); return (void*)1;
        }
    }
    close(fd);
    free(buf);
    std::printf("PASS cpu=%ld actual=%d reads=32\n", cpu, sched_getcpu());
    return nullptr;
}
int main()
{
    for (long cpu = 0; cpu < 2; ++cpu) {
        pthread_t t;
        if (pthread_create(&t, nullptr, read_queue, reinterpret_cast<void*>(cpu))) return 1;
        void* result;
        if (pthread_join(t, &result) || result) return 1;
    }
    std::puts("PASS shared IRQ guest pinned reads");
}
