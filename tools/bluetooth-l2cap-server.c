/* Forward one Bluetooth LE L2CAP connection at a time to Dropbear.
 * This freestanding helper uses the Linux AArch64 syscall ABI so it can be
 * built on the Mac without a Linux SDK or runtime libraries on the tablet.
 */

enum {
    SYS_FCNTL = 25, SYS_CLOSE = 57, SYS_WRITE = 64, SYS_PPOLL = 73,
    SYS_EXIT = 93, SYS_SOCKET = 198, SYS_BIND = 200, SYS_LISTEN = 201,
    SYS_CONNECT = 203, SYS_SENDTO = 206, SYS_RECVFROM = 207,
    SYS_SETSOCKOPT = 208, SYS_GETSOCKOPT = 209, SYS_ACCEPT4 = 242,
    AF_INET = 2, AF_BLUETOOTH = 31,
    SOCK_STREAM = 1, SOCK_SEQPACKET = 5, SOCK_NONBLOCK = 04000,
    SOCK_CLOEXEC = 02000000, F_SETFL = 4,
    SOL_BLUETOOTH = 274, BTPROTO_L2CAP = 0, BDADDR_LE_PUBLIC = 1,
    BT_SECURITY = 4, BT_SNDMTU = 12, BT_RCVMTU = 13,
    BT_SECURITY_LOW = 1, BT_SECURITY_MEDIUM = 2, BT_SECURITY_HIGH = 3,
    IPPROTO_TCP = 6, TCP_NODELAY = 1, MSG_TRUNC = 0x20, MSG_NOSIGNAL = 0x4000,
    POLLIN = 1, POLLOUT = 4, POLLERR = 8, POLLHUP = 16, POLLNVAL = 32,
    EINTR = 4, EAGAIN = 11,
    INKBRIDGE_PSM = 0x81, RECEIVE_MTU = 1024,
};

struct l2cap_address {
    unsigned short family;
    unsigned short psm;
    unsigned char address[6];
    unsigned short cid;
    unsigned char address_type;
};

struct ipv4_address {
    unsigned short family;
    unsigned short port;
    unsigned char address[4];
    unsigned char padding[8];
};

struct poll_fd {
    int fd;
    short events;
    short returned;
};

struct queue {
    unsigned char bytes[RECEIVE_MTU];
    unsigned length;
    unsigned offset;
};

static long system_call(long number, long first, long second, long third,
                        long fourth, long fifth, long sixth)
{
    register long x8 __asm__("x8") = number;
    register long x0 __asm__("x0") = first;
    register long x1 __asm__("x1") = second;
    register long x2 __asm__("x2") = third;
    register long x3 __asm__("x3") = fourth;
    register long x4 __asm__("x4") = fifth;
    register long x5 __asm__("x5") = sixth;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2),
                     "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
}

static void log_text(const char *message)
{
    unsigned length = 0;
    while (message[length])
        ++length;
    system_call(SYS_WRITE, 2, (long)message, length, 0, 0, 0);
}

static void log_error(const char *operation, long result)
{
    char digits[24];
    unsigned index = sizeof(digits) - 1;
    unsigned long error = result < 0 ? (unsigned long)-result : 0;
    digits[index] = '\0';
    do {
        digits[--index] = '0' + error % 10;
        error /= 10;
    } while (error);
    log_text(operation);
    log_text(" failed (errno ");
    log_text(digits + index);
    log_text(")\n");
}

static __attribute__((noreturn)) void stop(int status)
{
    system_call(SYS_EXIT, status, 0, 0, 0, 0, 0);
    __builtin_unreachable();
}

static long checked(const char *operation, long result)
{
    if (result < 0) {
        log_error(operation, result);
        stop(1);
    }
    return result;
}

static int read_decimal(const char **input, unsigned limit)
{
    const char *text = *input;
    unsigned value = 0;
    if (*text < '0' || *text > '9')
        return -1;
    do {
        value = value * 10 + (*text++ - '0');
        if (value > limit)
            return -1;
    } while (*text >= '0' && *text <= '9');
    *input = text;
    return (int)value;
}

static int read_address(const char *text, unsigned char address[4])
{
    for (unsigned index = 0; index < 4; ++index) {
        int part = read_decimal(&text, 255);
        if (part < 0 || *text != (index == 3 ? '\0' : '.'))
            return -1;
        address[index] = part;
        ++text;
    }
    return 0;
}

static int equal(const char *left, const char *right)
{
    while (*left && *left == *right) {
        ++left;
        ++right;
    }
    return *left == *right;
}

static int receive_bytes(int socket, struct queue *queue, int flags)
{
    long count = system_call(SYS_RECVFROM, socket, (long)queue->bytes,
                             sizeof(queue->bytes), flags, 0, 0);
    if (count == -EAGAIN || count == -EINTR)
        return 1;
    if (count < 0)
        log_error("receive", count);
    if (count > (long)sizeof(queue->bytes))
        log_text("Received an L2CAP packet larger than the negotiated MTU\n");
    if (count <= 0 || count > (long)sizeof(queue->bytes))
        return 0;
    queue->length = (unsigned)count;
    queue->offset = 0;
    return 1;
}

static int send_bytes(int socket, struct queue *queue, unsigned mtu)
{
    unsigned count = queue->length;
    if (mtu && count > mtu)
        count = mtu;
    long written = system_call(SYS_SENDTO, socket,
                               (long)(queue->bytes + queue->offset), count,
                               MSG_NOSIGNAL, 0, 0);
    if (written == -EAGAIN || written == -EINTR)
        return 1;
    if (written < 0)
        log_error("send", written);
    if (written <= 0 || (mtu && written != count))
        return 0;
    queue->length -= (unsigned)written;
    queue->offset += (unsigned)written;
    return 1;
}

static void proxy(int bluetooth, int ssh, unsigned bluetooth_mtu)
{
    struct queue for_bluetooth;
    struct queue for_ssh;
    for_bluetooth.length = 0;
    for_ssh.length = 0;
    struct poll_fd sockets[2];

    for (;;) {
        sockets[0].events = (for_ssh.length ? 0 : POLLIN)
            | (for_bluetooth.length ? POLLOUT : 0);
        sockets[1].events = (for_bluetooth.length ? 0 : POLLIN)
            | (for_ssh.length ? POLLOUT : 0);
        // Ignore hangups on a source while its last read is still being sent.
        sockets[0].fd = sockets[0].events ? bluetooth : -1;
        sockets[1].fd = sockets[1].events ? ssh : -1;
        long ready = system_call(SYS_PPOLL, (long)sockets, 2, 0, 0, 0, 0);
        if (ready == -EINTR)
            continue;
        if (ready < 0) {
            log_error("ppoll", ready);
            return;
        }

        short bluetooth_events = sockets[0].returned;
        short ssh_events = sockets[1].returned;
        if ((bluetooth_events | ssh_events) & (POLLERR | POLLNVAL))
            return;
        if ((bluetooth_events & (POLLOUT | POLLHUP)) && for_bluetooth.length &&
            !send_bytes(bluetooth, &for_bluetooth, bluetooth_mtu))
            return;
        if ((ssh_events & (POLLOUT | POLLHUP)) && for_ssh.length &&
            !send_bytes(ssh, &for_ssh, 0))
            return;
        if ((bluetooth_events & (POLLIN | POLLHUP)) && !for_ssh.length &&
            !receive_bytes(bluetooth, &for_ssh, MSG_TRUNC))
            return;
        if ((ssh_events & (POLLIN | POLLHUP)) && !for_bluetooth.length &&
            !receive_bytes(ssh, &for_bluetooth, 0))
            return;
    }
}

static void serve_client(int bluetooth, const struct ipv4_address *endpoint)
{
    unsigned short bluetooth_mtu = 0;
    unsigned length = sizeof(bluetooth_mtu);
    long result = system_call(SYS_GETSOCKOPT, bluetooth, SOL_BLUETOOTH,
                              BT_SNDMTU, (long)&bluetooth_mtu, (long)&length, 0);
    if (result < 0) {
        log_error("getsockopt(BT_SNDMTU)", result);
        return;
    }
    if (!bluetooth_mtu) {
        log_text("Bluetooth negotiated a zero send MTU\n");
        return;
    }

    long ssh = system_call(SYS_SOCKET, AF_INET, SOCK_STREAM | SOCK_CLOEXEC,
                           IPPROTO_TCP, 0, 0, 0);
    if (ssh < 0) {
        log_error("socket(SSH)", ssh);
        return;
    }
    result = system_call(SYS_CONNECT, ssh, (long)endpoint, sizeof(*endpoint), 0, 0, 0);
    if (result >= 0) {
        int enable = 1;
        system_call(SYS_SETSOCKOPT, ssh, IPPROTO_TCP, TCP_NODELAY,
                    (long)&enable, sizeof(enable), 0);
        result = system_call(SYS_FCNTL, ssh, F_SETFL, SOCK_NONBLOCK, 0, 0, 0);
        if (result >= 0)
            proxy((int)bluetooth, (int)ssh, bluetooth_mtu);
        else
            log_error("fcntl(SSH)", result);
    } else {
        log_error("connect(SSH)", result);
    }
    system_call(SYS_CLOSE, ssh, 0, 0, 0, 0, 0);
}

static __attribute__((noreturn)) void usage(void)
{
    log_text("Usage: inkbridge-bluetooth-l2cap-server [SSH_IPV4 [SSH_PORT [low|medium|high]]]\n");
    stop(2);
}

__attribute__((used, noinline, noreturn)) static void program(const long *stack)
{
    long argc = stack[0];
    const char *const *argv = (const char *const *)(stack + 1);
    struct ipv4_address endpoint = {.family = AF_INET, .address = {127, 0, 0, 1}};
    int port = 22;
    unsigned char security[2] = {BT_SECURITY_MEDIUM, 0};
    if (argc > 4 || (argc > 1 && read_address(argv[1], endpoint.address) < 0))
        usage();
    if (argc > 2) {
        const char *text = argv[2];
        port = read_decimal(&text, 65535);
        if (port < 1 || *text)
            usage();
    }
    if (argc > 3) {
        if (equal(argv[3], "low"))
            security[0] = BT_SECURITY_LOW;
        else if (equal(argv[3], "high"))
            security[0] = BT_SECURITY_HIGH;
        else if (!equal(argv[3], "medium"))
            usage();
    }
    endpoint.port = __builtin_bswap16((unsigned short)port);

    long listener = checked("socket(L2CAP)",
        system_call(SYS_SOCKET, AF_BLUETOOTH, SOCK_SEQPACKET | SOCK_CLOEXEC,
                    BTPROTO_L2CAP, 0, 0, 0));
    struct l2cap_address address = {
        .family = AF_BLUETOOTH, .psm = INKBRIDGE_PSM, .address_type = BDADDR_LE_PUBLIC,
    };
    checked("bind(L2CAP PSM 0x81)",
        system_call(SYS_BIND, listener, (long)&address, sizeof(address), 0, 0, 0));
    unsigned short receive_mtu = RECEIVE_MTU;
    checked("setsockopt(BT_RCVMTU)",
        system_call(SYS_SETSOCKOPT, listener, SOL_BLUETOOTH, BT_RCVMTU,
                    (long)&receive_mtu, sizeof(receive_mtu), 0));
    checked("setsockopt(BT_SECURITY)",
        system_call(SYS_SETSOCKOPT, listener, SOL_BLUETOOTH, BT_SECURITY,
                    (long)&security, sizeof(security), 0));
    checked("listen(L2CAP)", system_call(SYS_LISTEN, listener, 1, 0, 0, 0, 0));
    log_text("Listening on Bluetooth LE L2CAP PSM 0x81\n");

    for (;;) {
        long bluetooth = system_call(SYS_ACCEPT4, listener, 0, 0,
                                     SOCK_CLOEXEC | SOCK_NONBLOCK, 0, 0);
        if (bluetooth == -EINTR)
            continue;
        checked("accept4(L2CAP)", bluetooth);
        log_text("Bluetooth LE client connected\n");
        serve_client((int)bluetooth, &endpoint);
        system_call(SYS_CLOSE, bluetooth, 0, 0, 0, 0, 0);
        log_text("Bluetooth LE client disconnected\n");
    }
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile("mov x0, sp\nbl program\nbrk #0");
}
