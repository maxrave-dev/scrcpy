#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include "util/window_geometry.h"

int main(void) {
    struct sc_window_rect start = {100, 100, 300, 600};
    unsigned edges = sc_window_edges_at(0, 0, 300, 600, 6);
    assert(edges == (SC_WINDOW_EDGE_LEFT | SC_WINDOW_EDGE_TOP));
    assert(!sc_window_edges_at(150, 300, 300, 600, 6));
    assert(sc_window_edges_at(299, 599, 300, 600, 6) ==
           (SC_WINDOW_EDGE_RIGHT | SC_WINDOW_EDGE_BOTTOM));
    struct sc_window_rect r = sc_window_resize_rect(start, 30, 0,
                                                   SC_WINDOW_EDGE_RIGHT, .5);
    assert(r.x == 100 && r.y == 70 && r.w == 330 && r.h == 660);
    r = sc_window_resize_rect(start, 40, 80, edges, .5);
    assert(r.x == 140 && r.y == 180 && r.w == 260 && r.h == 520);
    r = sc_window_resize_rect(start, 999, 999, edges, .5);
    assert(r.w == 96 && r.h == 192 && r.x + r.w == 400 && r.y + r.h == 700);
    r = sc_window_resize_rect(start, -10, 20,
                             SC_WINDOW_EDGE_RIGHT | SC_WINDOW_EDGE_BOTTOM, 0);
    assert(r.x == 100 && r.y == 100 && r.w == 290 && r.h == 620);
    start = (struct sc_window_rect) {-900, -100, 800, 400};
    r = sc_window_resize_rect(start, 0, -40, SC_WINDOW_EDGE_TOP, 2);
    assert(r.y == -140 && r.h == 440 && r.w == 880 && r.x == -940);
    struct sc_window_rect content = {-400, 100, 300, 600};
    struct sc_window_titlebar_state hover = {0};
    // Hovering the screen body or a side edge must not reveal the titlebar.
    assert(!sc_window_titlebar_target(&hover, content, -250, 400, 0, false, 100));
    assert(!sc_window_titlebar_target(&hover, content, -395, 300, 0, false, 100));
    assert(sc_window_titlebar_target(&hover, content, -250, 115, 0, false, 100));
    assert(sc_window_titlebar_target(&hover, content, -250, 81, 0, false, 100));
    // Applying the returned target is the window adapter's responsibility.
    hover.visible = true;
    assert(sc_window_titlebar_target(&hover, content, -250, 75, 28, false, 200));
    assert(sc_window_titlebar_target(&hover, content, -250, 145, 28, false, 200));
    assert(sc_window_titlebar_target(&hover, content, -250, 170, 28, false, 1000));
    assert(sc_window_titlebar_target(&hover, content, -250, 170, 28, false, 1299));
    assert(!sc_window_titlebar_target(&hover, content, -250, 170, 28, false, 1300));
    // Returning near top cancels a pending hide instead of flickering.
    assert(sc_window_titlebar_target(&hover, content, -250, 110, 28, false, 1300));
    assert(hover.hide_at_ms == 0);
    assert(sc_window_titlebar_target(&hover, content, -250, 170, 28, false, 2000));
    assert(sc_window_titlebar_target(&hover, content, -250, 400, 28, true, 2400));
    assert(hover.hide_at_ms == 0); // A native drag must keep the bar visible.
    assert(sc_window_titlebar_target(&hover, content, -250, 400, 28, false, 2500));
    assert(!sc_window_titlebar_target(&hover, content, -250, 400, 28, false, 2800));
    hover.visible = false;
    assert(!sc_window_titlebar_target(&hover, content, -250, 115, 0, true, 3000));
    assert(!sc_window_titlebar_target(&hover, content, -50, 100, 0, false, 3000));
    content.y = -300; // Top-edge detection also works on a monitor above primary.
    assert(sc_window_titlebar_target(&hover, content, -250, -285, 0, false, 3100));
    puts("PASS: resize geometry, top-only titlebar hover, hysteresis, 300ms hide, drag guard, negative monitor coordinates");
    return 0;
}
