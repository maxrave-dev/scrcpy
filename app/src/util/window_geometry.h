#ifndef SC_WINDOW_GEOMETRY_H
#define SC_WINDOW_GEOMETRY_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

// Window-manager coordinates, not device pixels. Kept SDL-independent for tests.
struct sc_window_rect { int x, y, w, h; };
struct sc_window_titlebar_state {
    bool visible;
    uint64_t hide_at_ms;
};

// Only the top band reveals the bar. A wider retain band and delayed hide
// avoid flicker, including when the native titlebar extends above content.
// The caller commits visible only after the platform transition succeeds.
static inline bool
sc_window_titlebar_target(struct sc_window_titlebar_state *state,
                          struct sc_window_rect content, double mouse_x,
                          double mouse_y, int title_height, bool dragging,
                          uint64_t now_ms) {
    if (dragging) {
        state->hide_at_ms = 0;
        return state->visible;
    }
    int side_margin = state->visible ? 20 : 0;
    int above = state->visible ? title_height + 20 : 20;
    int below = state->visible ? 60 : 20;
    bool near_top = mouse_x >= content.x - side_margin
                 && mouse_x <= content.x + content.w + side_margin
                 && mouse_y >= content.y - above
                 && mouse_y <= content.y + below;
    if (!state->visible || near_top) {
        state->hide_at_ms = 0;
        return near_top;
    }
    if (!state->hide_at_ms) {
        state->hide_at_ms = now_ms + 300;
    }
    return now_ms < state->hide_at_ms;
}

enum sc_window_edge {
    SC_WINDOW_EDGE_LEFT = 1,
    SC_WINDOW_EDGE_RIGHT = 2,
    SC_WINDOW_EDGE_TOP = 4,
    SC_WINDOW_EDGE_BOTTOM = 8,
};

static inline unsigned
sc_window_edges_at(float x, float y, int width, int height, int margin) {
    unsigned edges = 0;
    if (x < margin) { edges |= SC_WINDOW_EDGE_LEFT; }
    else if (x >= width - margin) { edges |= SC_WINDOW_EDGE_RIGHT; }
    if (y < margin) { edges |= SC_WINDOW_EDGE_TOP; }
    else if (y >= height - margin) { edges |= SC_WINDOW_EDGE_BOTTOM; }
    return edges;
}

static inline struct sc_window_rect
sc_window_resize_rect(struct sc_window_rect start, double dx, double dy,
                      unsigned edges, double aspect) {
    double w = start.w;
    double h = start.h;
    unsigned horizontal = edges & (SC_WINDOW_EDGE_LEFT | SC_WINDOW_EDGE_RIGHT);
    unsigned vertical = edges & (SC_WINDOW_EDGE_TOP | SC_WINDOW_EDGE_BOTTOM);
    if (edges & SC_WINDOW_EDGE_LEFT) { w -= dx; }
    if (edges & SC_WINDOW_EDGE_RIGHT) { w += dx; }
    if (edges & SC_WINDOW_EDGE_TOP) { h -= dy; }
    if (edges & SC_WINDOW_EDGE_BOTTOM) { h += dy; }
    w = fmax(96, fmin(65535, w));
    h = fmax(96, fmin(65535, h));
    if (aspect > 0) {
        if (horizontal && (!vertical || fabs((w - start.w) / start.w)
                                    >= fabs((h - start.h) / start.h))) {
            h = w / aspect;
        } else {
            w = h * aspect;
        }
        if (w < 96) { w = 96; h = w / aspect; }
        if (h < 96) { h = 96; w = h * aspect; }
        // sc_size uses uint16_t; do not overflow it on extreme drags.
        if (w > 65535) { w = 65535; h = w / aspect; }
        if (h > 65535) { h = 65535; w = h * aspect; }
    }
    struct sc_window_rect result = start;
    result.w = (int) lround(w);
    result.h = (int) lround(h);
    if (edges & SC_WINDOW_EDGE_LEFT) { result.x += start.w - result.w; }
    else if (!horizontal) { result.x += (start.w - result.w) / 2; }
    if (edges & SC_WINDOW_EDGE_TOP) { result.y += start.h - result.h; }
    else if (!vertical) { result.y += (start.h - result.h) / 2; }
    return result;
}
#endif
