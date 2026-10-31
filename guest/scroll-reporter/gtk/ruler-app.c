// The GTK scroll reporter check's application (check.py gtk4-scroll-reports and
// gtk3-scroll-reports): a header bar over a scrolled window whose content shows, down its
// left edge, every 16 px band's index in 16 black or white 8 px blocks, the ruler
// guest/display/probe/src/scroll.rs reads back.
#include <gtk/gtk.h>

#define BAND 16
#define BANDS 750

static void draw_band(cairo_t *cr, int band) {
    cairo_set_source_rgb(cr, 0.5, 0.5, 0.5);
    cairo_paint(cr);
    for (int i = 0; i < 16; i++) {
        double v = (band >> (15 - i)) & 1;
        cairo_set_source_rgb(cr, v, v, v);
        cairo_rectangle(cr, 8 + i * 8, 0, 8, BAND);
        cairo_fill(cr);
    }
}

#if GTK_MAJOR_VERSION == 4
static void draw(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer band) { draw_band(cr, GPOINTER_TO_INT(band)); }

static void activate(GtkApplication *app) {
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "ruler");
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 800);
    gtk_window_set_titlebar(GTK_WINDOW(window), gtk_header_bar_new());
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    for (int b = 0; b < BANDS; b++) {
        GtkWidget *area = gtk_drawing_area_new();
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), BAND);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw, GINT_TO_POINTER(b), NULL);
        gtk_box_append(GTK_BOX(box), area);
    }
    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    gtk_window_set_child(GTK_WINDOW(window), scrolled);
    gtk_window_present(GTK_WINDOW(window));
}
#else
static gboolean draw(GtkWidget *area, cairo_t *cr, gpointer band) {
    draw_band(cr, GPOINTER_TO_INT(band));
    return TRUE;
}

static void activate(GtkApplication *app) {
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "ruler");
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 800);
    gtk_window_set_titlebar(GTK_WINDOW(window), gtk_header_bar_new());
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    for (int b = 0; b < BANDS; b++) {
        GtkWidget *area = gtk_drawing_area_new();
        gtk_widget_set_size_request(area, -1, BAND);
        g_signal_connect(area, "draw", G_CALLBACK(draw), GINT_TO_POINTER(b));
        gtk_box_pack_start(GTK_BOX(box), area, FALSE, FALSE, 0);
    }
    GtkWidget *scrolled = gtk_scrolled_window_new(NULL, NULL);
    gtk_container_add(GTK_CONTAINER(scrolled), box);
    gtk_container_add(GTK_CONTAINER(window), scrolled);
    gtk_widget_show_all(window);
}
#endif

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.caboose.ScrollRuler", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    return g_application_run(G_APPLICATION(app), argc, argv);
}
