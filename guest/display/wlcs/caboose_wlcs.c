/*
 * The WLCS integration for caboose-display (see README.md).
 *
 * WLCS, Mir's Wayland conformance suite, loads this library and uses it to start the
 * compositor, to connect clients to it, to place windows and to move a pointer and touch
 * contacts. Each server is a real caboose-display process with its own runtime directory;
 * everything WLCS asks of the compositor beyond its Wayland socket goes through the
 * compositor's control socket (docs/display.md, "Control socket"), so no test-only code
 * exists in the compositor.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <netinet/in.h>
#include <wayland-client.h>
#include <wlcs/display_server.h>
#include <wlcs/pointer.h>
#include <wlcs/touch.h>

#define MAX_CLIENTS 256
#define MAX_EXTENSIONS 128

struct caboose_server {
    WlcsDisplayServer base;
    pid_t pid;
    char runtime[128];
    char socket_path[192];
    char control_path[256];
    int control_fd;
    pthread_mutex_t control_lock;
    pthread_t settler;
    int settling;
    int clients;
    int client_fds[MAX_CLIENTS];
    long client_ordinals[MAX_CLIENTS];
    /* Connections made to the compositor so far: its control socket numbers them. */
    long connections;
    int next_slot;
    WlcsIntegrationDescriptor descriptor;
    WlcsExtensionDescriptor extensions[MAX_EXTENSIONS];
    char names[MAX_EXTENSIONS][64];
};

struct caboose_pointer {
    WlcsPointer base;
    struct caboose_server *server;
    double x, y;
    unsigned held;
};

struct caboose_touch {
    WlcsTouch base;
    struct caboose_server *server;
    int slot;
};

static void sleep_ms(long ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&t, NULL);
}

/* One request to the control socket; the answer line is copied to `answer`. */
static int control(struct caboose_server *s, char *answer, size_t size, const char *fmt, ...)
{
    char line[512];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(line, sizeof line - 1, fmt, args);
    va_end(args);
    if (n < 0 || n >= (int)sizeof line - 1)
        return -1;
    line[n++] = '\n';
    int ok = -1;
    pthread_mutex_lock(&s->control_lock);
    if (s->control_fd >= 0 && write(s->control_fd, line, n) == n) {
        size_t got = 0;
        char buf[65536];
        while (got < sizeof buf - 1) {
            ssize_t r = read(s->control_fd, buf + got, sizeof buf - 1 - got);
            if (r <= 0)
                break;
            got += r;
            if (memchr(buf, '\n', got))
                break;
        }
        buf[got] = 0;
        if (answer && size) {
            strncpy(answer, buf, size - 1);
            answer[size - 1] = 0;
        }
        ok = strstr(buf, "\"ok\":true") ? 0 : 1;
        if (getenv("CABOOSE_WLCS_TRACE") && strncmp(line, "settle", 6) != 0 && strncmp(line, "windows", 7) != 0)
            fprintf(stderr, "caboose-wlcs: %.*s -> %.200s", n - 1, line, buf);
    }
    pthread_mutex_unlock(&s->control_lock);
    return ok;
}

/* Nothing paces a seat nobody watches: release the clients' frame callbacks as a display
 * refreshing at about 60 Hz would. */
static void *settle_loop(void *arg)
{
    struct caboose_server *s = arg;
    while (s->settling) {
        control(s, NULL, 0, "settle");
        sleep_ms(8);
    }
    return NULL;
}

static int free_port(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t len = sizeof a;
    int port = 0;
    if (fd >= 0 && bind(fd, (struct sockaddr *)&a, sizeof a) == 0 && getsockname(fd, (struct sockaddr *)&a, &len) == 0)
        port = ntohs(a.sin_port);
    if (fd >= 0)
        close(fd);
    return port;
}

static int connect_unix(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    if (fd < 0)
        return -1;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

struct registry_state {
    struct caboose_server *server;
    size_t count;
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
                            uint32_t version)
{
    struct registry_state *r = data;
    (void)registry;
    (void)name;
    if (r->count >= MAX_EXTENSIONS)
        return;
    snprintf(r->server->names[r->count], sizeof r->server->names[0], "%s", interface);
    r->server->extensions[r->count].name = r->server->names[r->count];
    r->server->extensions[r->count].version = version;
    r->count++;
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

/* What the compositor really advertises is what WLCS may test: the descriptor is its registry. */
static void describe(struct caboose_server *s)
{
    int fd = connect_unix(s->socket_path);
    if (fd < 0)
        return;
    s->connections++;
    struct wl_display *display = wl_display_connect_to_fd(fd);
    if (!display) {
        close(fd);
        return;
    }
    struct registry_state state = {s, 0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &state);
    wl_display_roundtrip(display);
    s->descriptor.version = WLCS_INTEGRATION_DESCRIPTOR_VERSION;
    s->descriptor.num_extensions = state.count;
    s->descriptor.supported_extensions = s->extensions;
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
}

static void caboose_start(WlcsDisplayServer *base)
{
    struct caboose_server *s = (struct caboose_server *)base;
    snprintf(s->runtime, sizeof s->runtime, "/tmp/caboose-wlcs-XXXXXX");
    if (!mkdtemp(s->runtime)) {
        perror("caboose-wlcs: mkdtemp");
        abort();
    }
    chmod(s->runtime, 0700);
    char listen[64], env_file[192], log[192];
    snprintf(listen, sizeof listen, "127.0.0.1:%d", free_port());
    snprintf(env_file, sizeof env_file, "%s/env", s->runtime);
    snprintf(log, sizeof log, "%s/compositor.log", s->runtime);
    snprintf(s->socket_path, sizeof s->socket_path, "%s/wlcs", s->runtime);
    snprintf(s->control_path, sizeof s->control_path, "%s/caboose-display/wlcs/control.sock", s->runtime);

    const char *binary = getenv("CABOOSE_DISPLAY_BIN");
    s->pid = fork();
    if (s->pid == 0) {
        setenv("XDG_RUNTIME_DIR", s->runtime, 1);
        setenv("HOME", s->runtime, 1);
        unsetenv("WAYLAND_DISPLAY");
        unsetenv("DISPLAY");
        int out = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        dup2(out, 1);
        dup2(out, 2);
        execlp(binary && *binary ? binary : "caboose-display", "caboose-display", "--no-auth", "--no-xwayland",
               "--no-audio", "--no-games", "--no-devices", "--listen", listen, "--socket", "wlcs", "--env-file",
               env_file, (char *)NULL);
        _exit(127);
    }
    for (int waited = 0; access(env_file, F_OK) != 0; waited += 20) {
        int status;
        if (waitpid(s->pid, &status, WNOHANG) == s->pid || waited > 40000) {
            fprintf(stderr, "caboose-wlcs: caboose-display did not start; its log is %s\n", log);
            abort();
        }
        sleep_ms(20);
    }
    s->control_fd = connect_unix(s->control_path);
    if (s->control_fd < 0) {
        fprintf(stderr, "caboose-wlcs: no control socket at %s\n", s->control_path);
        abort();
    }
    describe(s);
    s->settling = 1;
    pthread_create(&s->settler, NULL, settle_loop, s);
}

static void caboose_stop(WlcsDisplayServer *base)
{
    struct caboose_server *s = (struct caboose_server *)base;
    if (s->settling) {
        s->settling = 0;
        pthread_join(s->settler, NULL);
    }
    if (s->control_fd >= 0)
        close(s->control_fd);
    s->control_fd = -1;
    if (s->pid > 0) {
        kill(s->pid, SIGTERM);
        for (int waited = 0; waited < 5000; waited += 10) {
            if (waitpid(s->pid, NULL, WNOHANG) == s->pid) {
                s->pid = 0;
                break;
            }
            sleep_ms(10);
        }
        if (s->pid > 0) {
            kill(s->pid, SIGKILL);
            waitpid(s->pid, NULL, 0);
            s->pid = 0;
        }
    }
    if (s->runtime[0]) {
        const char *keep = getenv("CABOOSE_WLCS_LOGS");
        char command[512];
        if (keep && *keep) {
            /* The compositor's log, kept by the server's pid, for a test that failed. */
            snprintf(command, sizeof command, "cp '%s/compositor.log' '%s/%s.log'", s->runtime, keep,
                     strrchr(s->runtime, '-') + 1);
            if (system(command) != 0)
                fprintf(stderr, "caboose-wlcs: could not keep the log\n");
        }
        snprintf(command, sizeof command, "rm -rf '%s'", s->runtime);
        if (system(command) != 0)
            fprintf(stderr, "caboose-wlcs: could not remove %s\n", s->runtime);
        s->runtime[0] = 0;
    }
}

static int caboose_create_client_socket(WlcsDisplayServer *base)
{
    struct caboose_server *s = (struct caboose_server *)base;
    int fd = connect_unix(s->socket_path);
    if (fd < 0)
        return fd;
    s->connections++;
    if (s->clients < MAX_CLIENTS) {
        s->client_fds[s->clients] = fd;
        s->client_ordinals[s->clients++] = s->connections;
    }
    return fd;
}

/* The integer after `"key":` in the window object that starts at `item`, or -1. */
static long field(const char *item, const char *key)
{
    char needle[48];
    snprintf(needle, sizeof needle, "\"%s\":", key);
    const char *at = strstr(item, needle);
    return at ? strtol(at + strlen(needle), NULL, 10) : -1;
}

static void caboose_position_window_absolute(WlcsDisplayServer *base, struct wl_display *client,
                                             struct wl_surface *surface, int x, int y)
{
    struct caboose_server *s = (struct caboose_server *)base;
    int fd = wl_display_get_fd(client);
    long ordinal = -1;
    for (int i = 0; i < s->clients; i++)
        if (s->client_fds[i] == fd)
            ordinal = s->client_ordinals[i];
    long id = wl_proxy_get_id((struct wl_proxy *)surface);
    /* The window is listed once the compositor has seen its first buffer. */
    for (int attempt = 0; attempt < 200; attempt++) {
        const size_t size = 1 << 20;
        char *answer = malloc(size);
        if (control(s, answer, size, "windows") >= 0) {
            for (char *item = strstr(answer, "{\"id\":"); item; item = strstr(item + 1, "{\"id\":")) {
                if (field(item, "client") == ordinal && field(item, "wl_surface") == id) {
                    long window = field(item, "id");
                    free(answer);
                    char reply[256];
                    if (control(s, reply, sizeof reply, "place %ld %d %d surface", window, x, y) != 0)
                        fprintf(stderr, "caboose-wlcs: place failed: %s", reply);
                    return;
                }
            }
        }
        free(answer);
        sleep_ms(10);
    }
    fprintf(stderr, "caboose-wlcs: no window for client %ld surface %ld\n", ordinal, id);
}

static const char *button_name(int code)
{
    switch (code) {
    case 0x110: return "left";
    case 0x111: return "right";
    case 0x112: return "middle";
    case 0x113: return "back";
    case 0x114: return "forward";
    default: return NULL;
    }
}

static void pointer_move_to(struct caboose_pointer *p, double x, double y, int relative, double dx, double dy)
{
    char reply[256];
    p->x = x;
    p->y = y;
    if (relative)
        control(p->server, reply, sizeof reply, "motion %.3f %.3f %.3f %.3f", x, y, dx, dy);
    else
        control(p->server, reply, sizeof reply, "move %.3f %.3f", x, y);
}

static void pointer_move_absolute(WlcsPointer *base, wl_fixed_t x, wl_fixed_t y)
{
    struct caboose_pointer *p = (struct caboose_pointer *)base;
    pointer_move_to(p, wl_fixed_to_double(x), wl_fixed_to_double(y), 0, 0, 0);
}

static void pointer_move_relative(WlcsPointer *base, wl_fixed_t dx, wl_fixed_t dy)
{
    struct caboose_pointer *p = (struct caboose_pointer *)base;
    double mx = wl_fixed_to_double(dx), my = wl_fixed_to_double(dy);
    pointer_move_to(p, p->x + mx, p->y + my, 1, mx, my);
}

static void pointer_button(WlcsPointer *base, int code, int down)
{
    struct caboose_pointer *p = (struct caboose_pointer *)base;
    const char *name = button_name(code);
    char reply[256];
    if (!name)
        return;
    control(p->server, reply, sizeof reply, "%s %.3f %.3f %s", down ? "press" : "release", p->x, p->y, name);
}

static void pointer_button_up(WlcsPointer *base, int code) { pointer_button(base, code, 0); }
static void pointer_button_down(WlcsPointer *base, int code) { pointer_button(base, code, 1); }
static void pointer_destroy(WlcsPointer *base) { free(base); }

static WlcsPointer *caboose_create_pointer(WlcsDisplayServer *base)
{
    struct caboose_pointer *p = calloc(1, sizeof *p);
    p->base.version = WLCS_POINTER_VERSION;
    p->base.move_absolute = pointer_move_absolute;
    p->base.move_relative = pointer_move_relative;
    p->base.button_up = pointer_button_up;
    p->base.button_down = pointer_button_down;
    p->base.destroy = pointer_destroy;
    p->server = (struct caboose_server *)base;
    return &p->base;
}

static void touch_event(struct caboose_touch *t, const char *phase, wl_fixed_t x, wl_fixed_t y)
{
    char reply[256];
    /* WLCS declares these wl_fixed_t but hands over whole pixels. */
    control(t->server, reply, sizeof reply, "touch %d %s %d %d", t->slot, phase, (int)x, (int)y);
}

static void touch_down(WlcsTouch *base, wl_fixed_t x, wl_fixed_t y) { touch_event((struct caboose_touch *)base, "down", x, y); }
static void touch_move(WlcsTouch *base, wl_fixed_t x, wl_fixed_t y) { touch_event((struct caboose_touch *)base, "motion", x, y); }
static void touch_up(WlcsTouch *base) { touch_event((struct caboose_touch *)base, "up", 0, 0); }
static void touch_destroy(WlcsTouch *base) { free(base); }

static WlcsTouch *caboose_create_touch(WlcsDisplayServer *base)
{
    struct caboose_server *s = (struct caboose_server *)base;
    struct caboose_touch *t = calloc(1, sizeof *t);
    t->base.version = WLCS_TOUCH_VERSION;
    t->base.touch_down = touch_down;
    t->base.touch_move = touch_move;
    t->base.touch_up = touch_up;
    t->base.destroy = touch_destroy;
    t->server = s;
    t->slot = s->next_slot++;
    return &t->base;
}

static WlcsIntegrationDescriptor const *caboose_get_descriptor(WlcsDisplayServer const *base)
{
    return &((struct caboose_server const *)base)->descriptor;
}

static WlcsDisplayServer *create_server(int argc, char const **argv)
{
    (void)argc;
    (void)argv;
    struct caboose_server *s = calloc(1, sizeof *s);
    s->base.version = WLCS_DISPLAY_SERVER_VERSION;
    s->base.start = caboose_start;
    s->base.stop = caboose_stop;
    s->base.create_client_socket = caboose_create_client_socket;
    s->base.position_window_absolute = caboose_position_window_absolute;
    s->base.create_pointer = caboose_create_pointer;
    s->base.create_touch = caboose_create_touch;
    s->base.get_descriptor = caboose_get_descriptor;
    s->control_fd = -1;
    pthread_mutex_init(&s->control_lock, NULL);
    return &s->base;
}

static void destroy_server(WlcsDisplayServer *base)
{
    free(base);
}

WlcsServerIntegration const wlcs_server_integration = {WLCS_SERVER_INTEGRATION_VERSION, create_server, destroy_server};
