/* Read evdev and emit compact pen snapshots over SSH on the Paper Pro.
 * Built for the Linux AArch64 syscall ABI without a tablet runtime dependency.
 */

enum {
    SYS_FCNTL = 25, SYS_IOCTL = 29, SYS_OPENAT = 56, SYS_READ = 63,
    SYS_WRITE = 64, SYS_PPOLL = 73, SYS_EXIT = 93, SYS_CLOCK_GETTIME = 113,
    AT_FDCWD = -100, F_GETFL = 3, F_SETFL = 4,
    O_NONBLOCK = 04000, O_CLOEXEC = 02000000, CLOCK_MONOTONIC = 1,
    POLLIN = 1, POLLOUT = 4, POLLERR = 8, POLLHUP = 16, POLLNVAL = 32,
    EINTR = 4, EAGAIN = 11,
    EV_SYN = 0, EV_KEY = 1, EV_ABS = 3, SYN_REPORT = 0, SYN_DROPPED = 3,
    ABS_X = 0, ABS_Y = 1, ABS_PRESSURE = 24, ABS_TILT_X = 26, ABS_TILT_Y = 27,
    BTN_TOOL_PEN = 320, BTN_TOOL_RUBBER = 321, BTN_TOUCH = 330,
    EVIOCGRAB = 0x40044590, EVIOCSCLOCKID = 0x400445a0,
    MOTION_PERIOD_NS = 8333334, EDGE_CAPACITY = 64,
};

static const long heartbeat_timeout_ns = 5000000000L;

struct timespec { long seconds, nanoseconds; };
struct poll_fd { int fd; short events, returned; };

struct input_event {
    long seconds, microseconds;
    unsigned short type, code;
    int value;
};

struct record {
    unsigned timestamp_ms;
    unsigned short x, y, pressure;
    signed char tilt_x, tilt_y;
    unsigned char flags;
    unsigned char reserved[3];
};

_Static_assert(sizeof(struct input_event) == 24, "evdev ABI");
_Static_assert(sizeof(struct record) == 16, "Inkbridge pen packet");

struct pen {
    int x, y, pressure, tilt_x, tilt_y;
    int pen, rubber, touch;
};

struct output {
    struct record edges[EDGE_CAPACITY];
    unsigned first, count;
    struct record motion, partial;
    int motion_pending;
    unsigned partial_offset;
    long next_motion;
};

static long system_call(long number, long first, long second, long third,
                        long fourth, long fifth)
{
    register long x8 __asm__("x8") = number;
    register long x0 __asm__("x0") = first;
    register long x1 __asm__("x1") = second;
    register long x2 __asm__("x2") = third;
    register long x3 __asm__("x3") = fourth;
    register long x4 __asm__("x4") = fifth;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2),
                     "r"(x3), "r"(x4) : "memory");
    return x0;
}

static __attribute__((noreturn)) void stop(int status)
{
    system_call(SYS_EXIT, status, 0, 0, 0, 0);
    __builtin_unreachable();
}

static __attribute__((noreturn)) void fail(const char *message)
{
    unsigned length = 0;
    while (message[length])
        ++length;
    system_call(SYS_WRITE, 2, (long)message, length, 0, 0);
    stop(1);
}

static long monotonic_ns(void)
{
    struct timespec time;
    if (system_call(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (long)&time, 0, 0, 0) < 0)
        fail("Inkbridge pen: could not read the monotonic clock\n");
    return time.seconds * 1000000000L + time.nanoseconds;
}

static int open_input(const char *path, int grab, const char *open_error,
                      const char *grab_error)
{
    int fd = (int)system_call(SYS_OPENAT, AT_FDCWD, (long)path,
                              O_NONBLOCK | O_CLOEXEC, 0, 0);
    if (fd < 0)
        fail(open_error);
    if (grab && system_call(SYS_IOCTL, fd, EVIOCGRAB, 1, 0, 0) < 0)
        fail(grab_error);
    return fd;
}

static void make_nonblocking(int fd)
{
    long flags = system_call(SYS_FCNTL, fd, F_GETFL, 0, 0, 0);
    if (flags < 0 || system_call(SYS_FCNTL, fd, F_SETFL, flags | O_NONBLOCK, 0, 0) < 0)
        fail("Inkbridge pen: could not make SSH I/O nonblocking\n");
}

static int axis(int fd, unsigned code)
{
    int values[6];  // input_absinfo, whose first member is the current value.
    unsigned request = 0x80184540 + code;  // EVIOCGABS(code)
    if (system_call(SYS_IOCTL, fd, request, (long)values, 0, 0) < 0)
        return 0;
    return values[0];
}

static void read_pen_state(int fd, struct pen *pen)
{
    unsigned char keys[96];
    unsigned request = 0x80004518 | (sizeof(keys) << 16);  // EVIOCGKEY(size)
    if (system_call(SYS_IOCTL, fd, request, (long)keys, 0, 0) < BTN_TOUCH / 8 + 1)
        fail("Inkbridge pen: could not query pen buttons\n");
    pen->pen = (keys[BTN_TOOL_PEN / 8] >> (BTN_TOOL_PEN % 8)) & 1;
    pen->rubber = (keys[BTN_TOOL_RUBBER / 8] >> (BTN_TOOL_RUBBER % 8)) & 1;
    pen->touch = (keys[BTN_TOUCH / 8] >> (BTN_TOUCH % 8)) & 1;
    pen->x = axis(fd, ABS_X);
    pen->y = axis(fd, ABS_Y);
    pen->pressure = axis(fd, ABS_PRESSURE);
    pen->tilt_x = axis(fd, ABS_TILT_X);
    pen->tilt_y = axis(fd, ABS_TILT_Y);
}

static void update_pen(struct pen *pen, const struct input_event *event)
{
    if (event->type == EV_ABS) {
        switch (event->code) {
        case ABS_X: pen->x = event->value; break;
        case ABS_Y: pen->y = event->value; break;
        case ABS_PRESSURE: pen->pressure = event->value; break;
        case ABS_TILT_X: pen->tilt_x = event->value; break;
        case ABS_TILT_Y: pen->tilt_y = event->value; break;
        }
    } else if (event->type == EV_KEY) {
        switch (event->code) {
        case BTN_TOOL_PEN: pen->pen = event->value != 0; break;
        case BTN_TOOL_RUBBER: pen->rubber = event->value != 0; break;
        case BTN_TOUCH: pen->touch = event->value != 0; break;
        }
    }
}

static int clamp(int value, int min, int max)
{
    if (value < min)
        return min;
    if (value > max)
        return max;
    return value;
}

static void queue_snapshot(struct output *output, const struct pen *pen,
                           unsigned timestamp, unsigned char *last_flags)
{
    struct record sample = {
        .timestamp_ms = timestamp,
        .x = clamp(pen->x, 0, 65535), .y = clamp(pen->y, 0, 65535),
        .pressure = clamp(pen->pressure, 0, 65535),
        .tilt_x = clamp(pen->tilt_x / 100, -127, 127),
        .tilt_y = clamp(pen->tilt_y / 100, -127, 127),
        .flags = (pen->pen || pen->rubber) | (pen->touch << 1) | (pen->rubber << 2),
    };
    if (sample.flags != *last_flags) {
        if (output->count == EDGE_CAPACITY)
            fail("Inkbridge pen: too many pen transitions waiting for SSH\n");
        output->edges[(output->first + output->count) % EDGE_CAPACITY] = sample;
        ++output->count;
        output->motion_pending = 0;
        *last_flags = sample.flags;
    } else if (sample.flags & 1) {
        output->motion = sample;
        output->motion_pending = 1;
    }
}

static void flush_output(struct output *output, long now)
{
    // Complete a partial record first, then send all pending state changes.
    for (;;) {
        struct record *sample;
        if (output->partial_offset)
            sample = &output->partial;
        else if (output->count)
            sample = &output->edges[output->first];
        else if (output->motion_pending && now >= output->next_motion)
            sample = &output->motion;
        else
            return;

        unsigned offset = output->partial_offset;
        const unsigned char *bytes = (const unsigned char *)sample;
        long written = system_call(SYS_WRITE, 1, (long)(bytes + offset),
                                    sizeof(*sample) - offset, 0, 0);
        if (written == -EAGAIN || written == -EINTR)
            return;
        if (written <= 0)
            stop(0);
        if (sample == &output->motion) {
            output->motion_pending = 0;
        } else if (sample != &output->partial) {
            output->first = (output->first + 1) % EDGE_CAPACITY;
            --output->count;
        }
        offset += (unsigned)written;
        if (offset < sizeof(*sample)) {
            output->partial = *sample;
            output->partial_offset = offset;
            return;
        }
        output->partial_offset = 0;
        output->next_motion = now + MOTION_PERIOD_NS;
    }
}

__attribute__((used, noinline, noreturn)) static void program(const long *stack)
{
    const char *const *argv = (const char *const *)(stack + 1);
    if (stack[0] != 4 || argv[1][0] != '/' ||
        (argv[2][0] != '/' && !(argv[2][0] == '-' && argv[2][1] == '\0')) ||
        (argv[3][0] != '0' && argv[3][0] != '1') || argv[3][1] != '\0')
        fail("Usage: inkbridge-bluetooth-pen /dev/input/eventN /dev/input/eventM|- 0|1\n");

    make_nonblocking(0);
    make_nonblocking(1);
    int pen_fd = open_input(argv[1], argv[3][0] == '1',
                            "Inkbridge pen: could not open pen input\n",
                            "Inkbridge pen: could not grab pen input\n");
    int touch_fd = -1;
    if (argv[2][0] == '/')
        touch_fd = open_input(argv[2], 1, "Inkbridge pen: could not open touch input\n",
                             "Inkbridge pen: could not grab touch input\n");

    int clock_id = CLOCK_MONOTONIC;
    int event_clock_is_monotonic =
        system_call(SYS_IOCTL, pen_fd, EVIOCSCLOCKID, (long)&clock_id, 0, 0) == 0;
    long now = monotonic_ns();
    long heartbeat_deadline = now + heartbeat_timeout_ns;
    struct output output;
    output.first = output.count = output.partial_offset = 0;
    output.motion_pending = 0;
    output.next_motion = now;
    struct pen pen;
    read_pen_state(pen_fd, &pen);
    unsigned char last_flags = 0;
    int dropped = 0;
    queue_snapshot(&output, &pen, (unsigned)(now / 1000000), &last_flags);

    struct poll_fd poll_fds[4] = {
        {.fd = 0, .events = POLLIN}, {.fd = pen_fd, .events = POLLIN},
        {.fd = touch_fd, .events = POLLIN}, {.fd = 1},
    };
    struct input_event events[64];
    const int disconnected = POLLERR | POLLHUP | POLLNVAL;
    for (;;) {
        now = monotonic_ns();
        if (now >= heartbeat_deadline)
            stop(0);
        long deadline = heartbeat_deadline;
        int output_ready = output.partial_offset || output.count;
        if (output.motion_pending) {
            if (now >= output.next_motion)
                output_ready = 1;
            else if (!output_ready && output.next_motion < deadline)
                deadline = output.next_motion;
        }
        poll_fds[3].events = output_ready ? POLLOUT : 0;
        long wait = deadline - now;
        struct timespec timeout = {wait / 1000000000L, wait % 1000000000L};
        long ready = system_call(SYS_PPOLL, (long)poll_fds, 4, (long)&timeout, 0, 0);
        if (ready == -EINTR)
            continue;
        if (ready < 0)
            fail("Inkbridge pen: could not poll inputs\n");
        if ((poll_fds[0].returned | poll_fds[3].returned) & disconnected)
            stop(0);
        if (poll_fds[0].returned & POLLIN) {
            char heartbeat[128];
            long count = system_call(SYS_READ, 0, (long)heartbeat, sizeof(heartbeat), 0, 0);
            if (count > 0)
                heartbeat_deadline = monotonic_ns() + heartbeat_timeout_ns;
            else if (count != -EAGAIN && count != -EINTR)
                stop(0);
        }
        if ((poll_fds[1].returned | poll_fds[2].returned) & disconnected)
            fail("Inkbridge pen: tablet input device disconnected\n");
        if (poll_fds[2].returned & POLLIN)
            system_call(SYS_READ, touch_fd, (long)events, sizeof(events), 0, 0);
        if (poll_fds[1].returned & POLLIN) {
            long bytes = system_call(SYS_READ, pen_fd, (long)events, sizeof(events), 0, 0);
            if (bytes == -EAGAIN || bytes == -EINTR)
                bytes = 0;
            else if (bytes <= 0 || bytes % (long)sizeof(*events))
                fail("Inkbridge pen: could not read a complete evdev event\n");
            for (unsigned index = 0; index < (unsigned)bytes / sizeof(*events); ++index) {
                const struct input_event *event = &events[index];
                if (event->type == EV_SYN && event->code == SYN_DROPPED) {
                    dropped = 1;
                } else if (event->type == EV_SYN && event->code == SYN_REPORT) {
                    if (dropped) {
                        read_pen_state(pen_fd, &pen);
                        dropped = 0;
                    }
                    long milliseconds = event_clock_is_monotonic
                        ? event->seconds * 1000L + event->microseconds / 1000L
                        : monotonic_ns() / 1000000L;
                    queue_snapshot(&output, &pen, (unsigned)milliseconds, &last_flags);
                } else if (!dropped) {
                    update_pen(&pen, event);
                }
            }
        }
        flush_output(&output, monotonic_ns());
    }
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile("mov x0, sp\nbl program\nbrk #0");
}
