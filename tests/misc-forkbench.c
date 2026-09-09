/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * misc-forkbench: time fork() the way a PostgreSQL postmaster pays for it.
 *
 * WHY THIS EXISTS
 * ---------------
 * PostgreSQL serves each client connection by fork()ing a backend, so client
 * connect latency contains one whole fork().  Measuring fork() through
 * PostgreSQL means measuring it through libpq, TCP, ZFS, the ARC, autovacuum and
 * the checkpointer at the same time.  This program isolates the variable: no
 * PostgreSQL, no driver, no filesystem, no network.
 *
 * WHAT DRIVES fork() COST ON OSv (and so what this program varies)
 * ---------------------------------------------------------------
 * OSv's fork() copies the parent's page tables in clone_address_space()
 * (core/mmu.cc).  Two things multiply into that walk:
 *
 *   1. RESIDENT PTE COUNT.  clone_pt_level0 visits every present leaf PTE.  A
 *      postmaster with shared_buffers=16GB and a touched heap has millions.  So
 *      -m <MiB> maps a MAP_SHARED|MAP_ANONYMOUS region and TOUCHES it (mapping
 *      alone creates no PTEs, and an untouched region would measure nothing --
 *      the classic way to accidentally report a fast fork).
 *
 *   2. LIVE THREAD COUNT.  clone_address_space builds one "share, do not COW"
 *      range per MAP_SHARED vma PLUS one per live thread (each thread's stack),
 *      and the per-PTE predicate addr_is_shared() scans that set.  OSv also pins
 *      ~2 threads per CPU, so this term grows with -smp even on an idle guest.
 *      -t <N> adds N sleeping threads on top.
 *
 * A third axis the hypothesis under test cares about is CONCURRENT BACKEND
 * COUNT: -w <N> keeps a rolling window of N live children (fork, and once N are
 * live, reap the oldest), exactly as a postmaster with N connected clients does.
 * If fork cost scales with the number of LIVE children rather than with the
 * work each fork does, that is a different bug from a slow walk.
 *
 * WHAT IS TIMED
 * -------------
 * The parent's fork() call itself, with CLOCK_MONOTONIC, one sample per fork.
 * That is the cost the postmaster's accept loop actually serialises on.  The
 * child does a trivial write (to prove COW is real and not deferred into
 * nothing) and _exit()s; child exit and reap time are NOT in the fork sample,
 * but are reported separately so a slow reap cannot hide as a fast fork.
 *
 * Percentiles, not just a mean: the mean of a bimodal fork distribution is a
 * number that describes no actual fork.
 *
 * USAGE
 *   forkbench [-m shared_MiB] [-t extra_threads] [-w window] [-n forks]
 *             [-p private_MiB] [-l label]
 *
 * Output: one "FORKBENCH" line of key=value pairs, greppable from a serial log,
 * plus a human summary.  Exits non-zero if any fork or reap failed, so a run
 * that silently stopped forking cannot be read as a fast result.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/* p in [0,100]; v must be sorted; n > 0. */
static double pct(const double *v, int n, double p)
{
	int i = (int)(p / 100.0 * (n - 1) + 0.5);
	if (i < 0)
		i = 0;
	if (i >= n)
		i = n - 1;
	return v[i];
}

static volatile int threads_stop;

static void *idle_thread(void *arg)
{
	/* A real live thread with a real stack, so clone_address_space sees it in
	 * numthreads() and adds its stack to the privatize/share range set.
	 * Sleeping, not spinning: this axis is about thread COUNT, not CPU load. */
	(void)arg;
	while (!threads_stop)
		usleep(200 * 1000);
	return NULL;
}

int main(int argc, char **argv)
{
	long shared_mib = 256;	 /* MAP_SHARED, touched: stands in for shared_buffers */
	long private_mib = 32;	 /* private dirty heap: stands in for a postmaster's own */
	int extra_threads = 0;
	int window = 1;		 /* concurrent live children */
	int nforks = 50;
	const char *label = "forkbench";
	int opt;

	while ((opt = getopt(argc, argv, "m:p:t:w:n:l:h")) != -1) {
		switch (opt) {
		case 'm': shared_mib = atol(optarg); break;
		case 'p': private_mib = atol(optarg); break;
		case 't': extra_threads = atoi(optarg); break;
		case 'w': window = atoi(optarg); break;
		case 'n': nforks = atoi(optarg); break;
		case 'l': label = optarg; break;
		default:
			fprintf(stderr,
				"usage: %s [-m shared_MiB] [-p private_MiB] "
				"[-t extra_threads] [-w window] [-n forks] [-l label]\n",
				argv[0]);
			return 2;
		}
	}
	if (window < 1) window = 1;
	if (nforks < 1) nforks = 1;

	/* ---- 1. Build a parent address space that looks like a postmaster. ---- */
	size_t shared_len = (size_t)shared_mib << 20;
	unsigned char *shm = NULL;
	if (shared_len) {
		shm = mmap(NULL, shared_len, PROT_READ | PROT_WRITE,
			   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
		if (shm == MAP_FAILED) {
			fprintf(stderr, "FORKBENCH FAIL: mmap shared %ld MiB: %s\n",
				shared_mib, strerror(errno));
			return 1;
		}
		/* TOUCH every page: an untouched mapping has no leaf PTEs, so the
		 * clone walk would have nothing to do and the benchmark would
		 * measure nothing while reporting success. */
		for (size_t off = 0; off < shared_len; off += 4096)
			shm[off] = 1;
	}

	size_t priv_len = (size_t)private_mib << 20;
	unsigned char *priv = NULL;
	if (priv_len) {
		priv = malloc(priv_len);
		if (!priv) {
			fprintf(stderr, "FORKBENCH FAIL: malloc private %ld MiB\n",
				private_mib);
			return 1;
		}
		memset(priv, 0xa5, priv_len);
	}

	pthread_t *tids = NULL;
	int threads_made = 0;
	if (extra_threads > 0) {
		tids = calloc(extra_threads, sizeof(*tids));
		if (!tids) {
			fprintf(stderr, "FORKBENCH FAIL: calloc tids\n");
			return 1;
		}
		for (int i = 0; i < extra_threads; i++) {
			if (pthread_create(&tids[i], NULL, idle_thread, NULL) != 0)
				break;
			threads_made++;
		}
		if (threads_made != extra_threads)
			fprintf(stderr, "FORKBENCH WARN: wanted %d threads, got %d\n",
				extra_threads, threads_made);
		/* Let them all reach their sleep loop so numthreads() is stable
		 * before the first timed fork. */
		usleep(300 * 1000);
	}

	/* ---- 2. The fork/reap loop with a rolling window of live children. ---- */
	double *samples = calloc(nforks, sizeof(*samples));
	double *reaps = calloc(nforks, sizeof(*reaps));
	pid_t *live = calloc(window, sizeof(*live));
	if (!samples || !reaps || !live) {
		fprintf(stderr, "FORKBENCH FAIL: calloc results\n");
		return 1;
	}
	int nlive = 0, nsample = 0, nreap = 0, fork_fail = 0, reap_fail = 0;

	double wall0 = now_ms();
	for (int i = 0; i < nforks; i++) {
		/* Keep the window full but not over: reap the oldest first. */
		if (nlive == window) {
			int status = 0;
			double r0 = now_ms();
			pid_t got = waitpid(live[0], &status, 0);
			reaps[nreap++] = now_ms() - r0;
			if (got != live[0] || !WIFEXITED(status) ||
			    WEXITSTATUS(status) != 42)
				reap_fail++;
			memmove(live, live + 1, (size_t)(nlive - 1) * sizeof(*live));
			nlive--;
		}

		double t0 = now_ms();
		pid_t pid = fork();
		if (pid == 0) {
			/* Child: write to the inherited shared region and to private
			 * heap, so COW is genuinely exercised, then leave.  _exit,
			 * not exit: no atexit/stdio flush noise in the measurement. */
			if (shm)
				shm[0] = 2;
			if (priv)
				priv[0] = 0x5a;
			_exit(42);
		}
		double dt = now_ms() - t0;
		if (pid < 0) {
			fork_fail++;
			/* A failing fork is fast; recording it as a sample would
			 * report a speedup that is really an outage. */
			continue;
		}
		samples[nsample++] = dt;
		live[nlive++] = pid;
	}
	/* Drain the window. */
	while (nlive > 0) {
		int status = 0;
		double r0 = now_ms();
		pid_t got = waitpid(live[0], &status, 0);
		reaps[nreap++] = now_ms() - r0;
		if (got != live[0] || !WIFEXITED(status) || WEXITSTATUS(status) != 42)
			reap_fail++;
		memmove(live, live + 1, (size_t)(nlive - 1) * sizeof(*live));
		nlive--;
	}
	double wall = now_ms() - wall0;

	threads_stop = 1;

	/* ---- 3. Report. ---- */
	double sum = 0;
	for (int i = 0; i < nsample; i++)
		sum += samples[i];
	double reap_sum = 0;
	for (int i = 0; i < nreap; i++)
		reap_sum += reaps[i];
	qsort(samples, (size_t)nsample, sizeof(*samples), cmp_double);
	qsort(reaps, (size_t)nreap, sizeof(*reaps), cmp_double);

	/* forks/sec two ways, because they answer different questions:
	 *   fps_wall  = nforks / total wall  -> sustained throughput incl. reap
	 *   fps_fork  = 1000 / mean ms/fork  -> the serialised fork cost alone */
	double mean = nsample ? sum / nsample : 0;
	double fps_wall = wall > 0 ? nsample * 1000.0 / wall : 0;
	double fps_fork = mean > 0 ? 1000.0 / mean : 0;

	printf("FORKBENCH label=%s shared_mib=%ld private_mib=%ld pages_shared=%ld "
	       "extra_threads=%d window=%d n=%d fork_fail=%d reap_fail=%d "
	       "mean_ms=%.2f p50_ms=%.2f p90_ms=%.2f p99_ms=%.2f min_ms=%.2f max_ms=%.2f "
	       "fps_fork=%.2f fps_wall=%.2f wall_ms=%.1f "
	       "reap_mean_ms=%.2f reap_p50_ms=%.2f reap_max_ms=%.2f\n",
	       label, shared_mib, private_mib, (long)(shared_len / 4096),
	       threads_made, window, nsample, fork_fail, reap_fail,
	       mean,
	       nsample ? pct(samples, nsample, 50) : 0,
	       nsample ? pct(samples, nsample, 90) : 0,
	       nsample ? pct(samples, nsample, 99) : 0,
	       nsample ? samples[0] : 0,
	       nsample ? samples[nsample - 1] : 0,
	       fps_fork, fps_wall, wall,
	       nreap ? reap_sum / nreap : 0,
	       nreap ? pct(reaps, nreap, 50) : 0,
	       nreap ? reaps[nreap - 1] : 0);
	fflush(stdout);

	if (fork_fail || reap_fail || nsample == 0) {
		printf("FORKBENCH RESULT=FAIL (fork_fail=%d reap_fail=%d n=%d)\n",
		       fork_fail, reap_fail, nsample);
		fflush(NULL);
		/* _exit, not return: the -t threads are parked in usleep() and OSv
		 * keeps the guest alive until every application thread exits, so a
		 * plain return hangs the run until the harness timeout kills it --
		 * which silently turns every threaded cell into a 15-minute stall.
		 * The measurement is complete and printed by now, so leave hard. */
		_exit(1);
	}
	printf("FORKBENCH RESULT=OK\n");
	fflush(NULL);
	_exit(0);
}
