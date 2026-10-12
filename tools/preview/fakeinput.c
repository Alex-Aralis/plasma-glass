// Pointer input for the preview's virtual KWin (org_kde_kwin_fake_input; session.sh starts KWin with
// KWIN_WAYLAND_NO_PERMISSION_CHECKS so it accepts this client). Reads commands from stdin:
//   move X Y     pointer to X,Y (logical pixels, absolute)
//   by DX DY     relative pointer motion
//   down | up    left button
//   key CODE down|up   keyboard key (evdev code from linux/input-event-codes.h, e.g. 125 = left Meta)
//   wait MS      flush, then pause
// Lines starting with # are ignored. Built by common.sh on first use.
#define _POSIX_C_SOURCE 200809L
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "fake-input-client-protocol.h"

static struct org_kde_kwin_fake_input *fake;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
    (void)data;
    if (strcmp(interface, org_kde_kwin_fake_input_interface.name) == 0 && version >= 4)
        fake = wl_registry_bind(registry, name, &org_kde_kwin_fake_input_interface, 4);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data, (void)registry, (void)name;
}

static const struct wl_registry_listener registry_listener = {global, global_remove};

int main(void)
{
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "fakeinput: can't connect to the Wayland display\n");
        return 1;
    }
    wl_registry_add_listener(wl_display_get_registry(display), &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!fake) {
        fprintf(stderr, "fakeinput: the compositor offers no org_kde_kwin_fake_input (version 4+)\n");
        return 1;
    }
    org_kde_kwin_fake_input_authenticate(fake, "plasma-glass preview", "drive the preview display");

    char line[256], state[8];
    double a, b;
    unsigned code;
    while (fgets(line, sizeof line, stdin)) {
        if (sscanf(line, "move %lf %lf", &a, &b) == 2) {
            org_kde_kwin_fake_input_pointer_motion_absolute(fake, wl_fixed_from_double(a), wl_fixed_from_double(b));
        } else if (sscanf(line, "by %lf %lf", &a, &b) == 2) {
            org_kde_kwin_fake_input_pointer_motion(fake, wl_fixed_from_double(a), wl_fixed_from_double(b));
        } else if (strncmp(line, "down", 4) == 0) {
            org_kde_kwin_fake_input_button(fake, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
        } else if (strncmp(line, "up", 2) == 0) {
            org_kde_kwin_fake_input_button(fake, BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
        } else if (sscanf(line, "key %u %7s", &code, state) == 2) {
            org_kde_kwin_fake_input_keyboard_key(fake, code, strcmp(state, "down") == 0 ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
        } else if (sscanf(line, "wait %lf", &a) == 1) {
            wl_display_roundtrip(display);
            struct timespec ts = {(time_t)(a / 1000), (long)((a - (time_t)(a / 1000) * 1000) * 1e6)};
            nanosleep(&ts, NULL);
            continue;
        } else if (line[0] == '#' || line[0] == '\n') {
            continue;
        } else {
            fprintf(stderr, "fakeinput: unknown command: %s", line);
            return 2;
        }
        wl_display_flush(display);
    }
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
