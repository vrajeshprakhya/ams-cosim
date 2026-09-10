/*
 * ams_bridge -- couple a SystemVerilog simulator to ngspice, in lockstep.
 *
 * xezim is the MASTER and ngspice the slave, because that is the only
 * direction the two can be driven. xezim calls out through DPI-C
 * (`--dpi-lib`, dlopen/dlsym) and cannot itself be stepped from outside --
 * it has no library mode and no resume entry point. libngspice can be
 * driven, through the synchronisation callbacks ngSpice_Init_Sync installs
 * for exactly this purpose.
 *
 * THE HANDSHAKE, which is the whole of the difficulty.
 *
 * libngspice runs its transient on ITS OWN background thread (bg_run), so
 * the two simulators genuinely run concurrently and something has to stop
 * the analog side from running ahead of the digital one. ngspice offers one
 * hook for that: GetSyncData, which it calls inside dctran with the time it
 * has reached and a pointer to the timestep it intends to take next. So:
 *
 *   - the digital side calls ams_advance(t): "you may run up to t"
 *   - GetSyncData CLAMPS ngspice's next step so it cannot pass t, and
 *     BLOCKS once it has arrived
 *   - ams_advance returns when ngspice reports it has reached t
 *
 * The clamp matters as much as the block. Without it ngspice picks a step
 * from its own error control, overshoots t, and the digital side then reads
 * a voltage from the future -- which does not fail, it just quietly makes
 * the coupling wrong by up to one analog timestep.
 *
 * GetVSRCData is deliberately NOT a synchronisation point. ngspice asks for
 * a source value once per Newton iteration, several times per timestep, and
 * blocking there would deadlock against its own solver. It returns the last
 * value the digital side wrote, which is the correct semantics: a source
 * holds its value across the step being solved.
 *
 * WHAT THIS IS FOR. Not speed -- the analog side is transistor-level SPICE
 * and sets the pace, so this is minutes-to-hours where an RNM is
 * milliseconds. It is for a GOLDEN: a reference run of the real circuit
 * against the real RTL, to check a generated model against. Nothing here
 * belongs in a per-change verification loop.
 */
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* stdbool.h above is REQUIRED, and must precede this include.
 *
 * sharedspice.h has `typedef bool NG_BOOL;` and does not include stdbool.h
 * itself, so before C23 -- where `bool` became a keyword -- every caller has
 * to provide it. Omitting it is invisible on a new toolchain and fatal on an
 * older one: gcc 15 defaults to gnu23 and compiles this fine, while gcc 13
 * defaults to gnu17 and stops at
 *
 *     sharedspice.h:158:9: error: unknown type name 'bool'
 *
 * which reads like a broken ngspice header rather than a missing include
 * here. Found when CI on ubuntu-latest failed against a local build that
 * had never had a reason to complain.
 */
#include "sharedspice.h"

#ifndef AMS_MAX_NODES
#define AMS_MAX_NODES 32
#endif

/* Below this much remaining room, stop clamping the analog timestep and
 * let it overshoot instead -- see cb_get_sync. 0.1 ps is far under any
 * digital tick worth coupling at and far over the 1e-25 the clamp
 * collapsed to. */
#ifndef AMS_MIN_STEP_S
#define AMS_MIN_STEP_S 1.0e-13
#endif

/* One entry per node the digital side drives into the analog. */
struct dig_node {
    char   name[64];
    double value;
};

static struct {
    pthread_mutex_t mtx;
    pthread_cond_t  cv;

    int    open;          /* ngspice initialised */
    int    running;       /* bg_run issued and not yet finished */
    int    finished;      /* ngspice reported the run is over */
    int    started;       /* the transient has actually begun */

    double allow_until;   /* how far the digital side has permitted */
    double ng_time;       /* how far ngspice reports it has reached */

    struct dig_node dig[AMS_MAX_NODES];
    int    n_dig;

    int    verbose;
} G;

static void lock(void)   { pthread_mutex_lock(&G.mtx); }
static void unlock(void) { pthread_mutex_unlock(&G.mtx); }

/* ---------------------------------------------------------------- ngspice
 * callbacks. These run on ngspice's thread.
 */

static int cb_send_char(char *what, int id, void *user)
{
    (void)id; (void)user;
    if (G.verbose && what)
        fprintf(stderr, "[ngspice] %s\n", what);
    return 0;
}

static int cb_send_stat(char *what, int id, void *user)
{
    (void)what; (void)id; (void)user;
    return 0;
}

static int cb_exit(int status, NG_BOOL immediate, NG_BOOL quit, int id,
                   void *user)
{
    (void)immediate; (void)quit; (void)id; (void)user;
    /* Never let ngspice take the process down: this runs inside the
     * digital simulator, and exit() here would kill the whole run with no
     * indication of which side failed. */
    lock();
    G.finished = 1;
    G.running = 0;
    pthread_cond_broadcast(&G.cv);
    unlock();
    fprintf(stderr, "[ams_bridge] ngspice exited (status %d)\n", status);
    return 0;
}

static int cb_bg_running(NG_BOOL not_running, int id, void *user)
{
    (void)id; (void)user;
    lock();
    G.running = !not_running;
    if (not_running) {
        G.finished = 1;
        pthread_cond_broadcast(&G.cv);
    }
    unlock();
    return 0;
}

/* A voltage source the digital side drives. Called once per Newton
 * iteration -- NOT a place to block; see the header comment. */
static int cb_get_vsrc(double *ret, double t, char *node, int id, void *user)
{
    (void)t; (void)id; (void)user;
    int i;
    lock();
    *ret = 0.0;
    for (i = 0; i < G.n_dig; i++) {
        if (strcmp(G.dig[i].name, node) == 0) {
            *ret = G.dig[i].value;
            break;
        }
    }
    unlock();
    return 0;
}

static int cb_get_isrc(double *ret, double t, char *node, int id, void *user)
{
    return cb_get_vsrc(ret, t, node, id, user);
}

/* The synchronisation point. Clamp the step so ngspice cannot pass the
 * time the digital side allowed, and wait once it has arrived. */
static int cb_get_sync(double actual_time, double *delta_time, double olddelta,
                       int redostep, int id, int location, void *user)
{
    (void)olddelta; (void)redostep; (void)id; (void)location; (void)user;

    lock();
    G.started = 1;
    G.ng_time = actual_time;
    pthread_cond_broadcast(&G.cv);

    while (actual_time >= G.allow_until && !G.finished)
        pthread_cond_wait(&G.cv, &G.mtx);

    if (!G.finished) {
        double room = G.allow_until - actual_time;
        /* Clamp so the analog cannot run past what the digital side has
         * allowed -- but only while there is real room left.
         *
         * Clamping all the way to zero is what an obvious implementation
         * does and it destroys the run: as ngspice approaches allow_until,
         * `room` shrinks, the clamp shrinks the step with it, and the two
         * chase each other down until ngspice reports "Timestep too small;
         * timestep = 8.8e-25" and aborts the transient. Measured on the
         * PLL at t=3 ns.
         *
         * Below the floor, leave the step alone and let ngspice overshoot
         * by at most one of ITS steps; the block above catches it on the
         * next call. That bounds the error at one analog timestep, which is
         * far smaller than the digital tick that granted the window, and
         * unlike the squeeze it cannot fail. */
        if (room > AMS_MIN_STEP_S && *delta_time > room)
            *delta_time = room;
    }
    unlock();
    return 0;
}

/* -------------------------------------------------------------------- DPI
 * Everything below runs on the digital simulator's thread.
 */

int ams_open(const char *deck_path)
{
    static int inited;
    int rc;

    if (!inited) {
        pthread_mutex_init(&G.mtx, NULL);
        pthread_cond_init(&G.cv, NULL);
        inited = 1;
    }
    memset(G.dig, 0, sizeof G.dig);
    G.n_dig = 0;
    G.allow_until = 0.0;
    G.ng_time = 0.0;
    G.finished = G.running = G.started = 0;
    G.verbose = getenv("AMS_BRIDGE_VERBOSE") != NULL;

    rc = ngSpice_Init(cb_send_char, cb_send_stat, cb_exit,
                      NULL, NULL, cb_bg_running, NULL);
    if (rc != 0) {
        fprintf(stderr, "[ams_bridge] ngSpice_Init failed (%d)\n", rc);
        return rc;
    }
    rc = ngSpice_Init_Sync(cb_get_vsrc, cb_get_isrc, cb_get_sync, NULL, NULL);
    if (rc != 0) {
        fprintf(stderr, "[ams_bridge] ngSpice_Init_Sync failed (%d)\n", rc);
        return rc;
    }

    {
        char cmd[1024];
        snprintf(cmd, sizeof cmd, "source %s", deck_path);
        rc = ngSpice_Command(cmd);
        if (rc != 0) {
            fprintf(stderr, "[ams_bridge] could not source %s (%d)\n",
                    deck_path, rc);
            return rc;
        }
    }
    G.open = 1;
    return 0;
}

/* Register a node the digital side drives. The deck must declare it as an
 * external source (`Vname node 0 dc 0 external`). */
int ams_drive(const char *node, double initial)
{
    if (G.n_dig >= AMS_MAX_NODES) {
        fprintf(stderr, "[ams_bridge] too many driven nodes (max %d)\n",
                AMS_MAX_NODES);
        return -1;
    }
    lock();
    snprintf(G.dig[G.n_dig].name, sizeof G.dig[0].name, "%s", node);
    G.dig[G.n_dig].value = initial;
    G.n_dig++;
    unlock();
    return 0;
}

int ams_set(const char *node, double value)
{
    int i, found = 0;
    lock();
    for (i = 0; i < G.n_dig; i++) {
        if (strcmp(G.dig[i].name, node) == 0) {
            G.dig[i].value = value;
            found = 1;
            break;
        }
    }
    unlock();
    if (!found)
        fprintf(stderr, "[ams_bridge] ams_set: %s is not a driven node\n",
                node);
    return found ? 0 : -1;
}

/* Start the transient. `stop_s` bounds the whole run; the digital side
 * still gates progress through ams_advance. */
int ams_start(double tstep_s, double stop_s)
{
    char cmd[256];
    int rc;

    if (!G.open) {
        fprintf(stderr, "[ams_bridge] ams_start before ams_open\n");
        return -1;
    }
    /* A first window, so ngspice can take its operating point and reach the
     * sync callback rather than blocking before it ever runs. */
    lock();
    if (G.allow_until <= 0.0)
        G.allow_until = tstep_s;
    unlock();

    snprintf(cmd, sizeof cmd, "bg_tran %.12g %.12g", tstep_s, stop_s);
    rc = ngSpice_Command(cmd);
    if (rc != 0) {
        fprintf(stderr, "[ams_bridge] %s failed (%d)\n", cmd, rc);
        return rc;
    }
    lock();
    G.running = 1;
    unlock();
    return 0;
}

/* Let the analog run to `t_stop` seconds, and return once it is there. */
int ams_advance(double t_stop)
{
    struct timespec ts;
    int rc = 0;

    lock();
    if (t_stop > G.allow_until)
        G.allow_until = t_stop;
    pthread_cond_broadcast(&G.cv);

    while (G.ng_time < t_stop && !G.finished) {
        /* Timed wait rather than an indefinite one: if ngspice dies without
         * the exit callback firing, an untimed wait hangs the digital
         * simulator with no message, which is the worst failure available. */
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 10;
        if (pthread_cond_timedwait(&G.cv, &G.mtx, &ts) == ETIMEDOUT) {
            fprintf(stderr,
                    "[ams_bridge] analog stalled at t=%.6g s waiting for "
                    "%.6g s (started=%d running=%d)\n",
                    G.ng_time, t_stop, G.started, G.running);
            rc = -1;
            break;
        }
    }
    if (G.finished && G.ng_time < t_stop)
        rc = 1;              /* the analog run ended early; not an error */
    unlock();
    return rc;
}

/* Read a node voltage from the analog side. */
double ams_get(const char *node)
{
    char vec[128];
    pvector_info vi;
    double v = 0.0;

    snprintf(vec, sizeof vec, "%s", node);
    vi = ngGet_Vec_Info(vec);
    if (vi == NULL || vi->v_length <= 0) {
        /* ngspice names transient vectors plainly, but a node inside a
         * subcircuit is `x1.node`; report rather than return a silent 0. */
        fprintf(stderr, "[ams_bridge] no vector %s\n", vec);
        return 0.0;
    }
    if (vi->v_realdata != NULL)
        v = vi->v_realdata[vi->v_length - 1];
    else if (vi->v_compdata != NULL)
        v = vi->v_compdata[vi->v_length - 1].cx_real;
    return v;
}

/* Write the analog side's waveform to an ngspice rawfile.
 *
 * `vectors` is a space-separated list ("v(aout) v(vout)"), or empty for
 * everything ngspice kept. This ENDS the analog run: ngspice refuses to
 * write while the background thread is going --
 *
 *     cannot execute "write ...", type "bg_halt" first
 *
 * -- so this halts first. Call it at the end of the digital run, not
 * partway through.
 *
 * A rawfile rather than a VCD because that is ngspice's native format and
 * it is lossless: it carries the solver's OWN timepoints, which are neither
 * uniform nor the coupling ticks. Converting to VCD here would mean
 * resampling an analog waveform onto the digital grid, which is the step
 * that turns a real waveform into a plausible-looking one. Read it with
 * ngspice itself, gaw, or numpy.
 */
int ams_write_raw(const char *path, const char *vectors)
{
    char cmd[1024];
    struct timespec ts;
    FILE *f;

    if (!G.open) {
        fprintf(stderr, "[ams_bridge] ams_write_raw before ams_open\n");
        return -1;
    }

    /* Halt, and wait for the thread to actually stop -- issuing `write`
     * immediately after `bg_halt` races the background thread. */
    lock();
    G.allow_until = 1e30;          /* release anyone blocked in the sync cb */
    pthread_cond_broadcast(&G.cv);
    unlock();
    ngSpice_Command("bg_halt");
    lock();
    while (G.running && !G.finished) {
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 5;
        if (pthread_cond_timedwait(&G.cv, &G.mtx, &ts) == ETIMEDOUT)
            break;
    }
    unlock();

    if (vectors && *vectors)
        snprintf(cmd, sizeof cmd, "write %s %s", path, vectors);
    else
        snprintf(cmd, sizeof cmd, "write %s", path);
    if (G.verbose)
        fprintf(stderr, "[ams_bridge] %s\n", cmd);
    ngSpice_Command(cmd);

    /* ngSpice_Command returns 0 even for a command it refused -- the first
     * version of this trusted that return and reported a file it had not
     * written. Check the file instead. */
    f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "[ams_bridge] ngspice wrote no %s\n", path);
        return -1;
    }
    fclose(f);
    return 0;
}

double ams_time(void)
{
    double t;
    lock();
    t = G.ng_time;
    unlock();
    return t;
}

int ams_done(void)
{
    int d;
    lock();
    d = G.finished;
    unlock();
    return d;
}

void ams_close(void)
{
    if (!G.open)
        return;
    lock();
    G.finished = 1;
    G.allow_until = 1e30;      /* release anyone blocked in the sync callback */
    pthread_cond_broadcast(&G.cv);
    unlock();
    ngSpice_Command("bg_halt");
    G.open = 0;
}
