#include "qemu/osdep.h"
#include "qemu/module.h"
#include "sysemu/sysemu.h"
#include "ui/console.h"
#include "ui/egl-helpers.h"
#include "ui/egl-context.h"
#include "ui/shader.h"

typedef struct egl_dpy {
    DisplayChangeListener dcl;
    DisplaySurface *ds;
    QemuGLShader *gls;
    egl_fb guest_fb;
    egl_fb cursor_fb;
    egl_fb blit_fb;
    bool y_0_top;
    uint32_t pos_x;
    uint32_t pos_y;
} egl_dpy;

#ifndef CONFIG_GBM
static EGLContext ctx;
#endif

/* ------------------------------------------------------------------ */

static void egl_refresh(DisplayChangeListener *dcl)
{
    graphic_hw_update(dcl->con);
}

static void egl_gfx_update(DisplayChangeListener *dcl,
                           int x, int y, int w, int h)
{
}

static void egl_gfx_switch(DisplayChangeListener *dcl,
                           struct DisplaySurface *new_surface)
{
    egl_dpy *edpy = container_of(dcl, egl_dpy, dcl);

    edpy->ds = new_surface;
}

static QEMUGLContext egl_create_context(void *dg,
                                        QEMUGLParams *params)
{
#ifdef CONFIG_GBM
    eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   qemu_egl_rn_ctx);
#else
    eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
#endif
    return qemu_egl_create_context(dg, params);
}

static bool egl_scanout_get_enabled(void *dg)
{
    return ((egl_dpy *)dg)->guest_fb.texture != 0;
}

static void egl_scanout_disable(void *dg)
{
    egl_dpy *edpy = dg;
    egl_fb_destroy(&edpy->guest_fb);
    egl_fb_destroy(&edpy->blit_fb);
}

static void egl_scanout_imported_texture(void *dg,
                                         uint32_t backing_texture,
                                         bool backing_y_0_top,
                                         uint32_t backing_width,
                                         uint32_t backing_height)
{
    egl_dpy *edpy = dg;

    edpy->y_0_top = backing_y_0_top;

    /* source framebuffer */
    egl_fb_setup_for_tex(&edpy->guest_fb,
                         backing_width, backing_height, backing_texture, false);

    /* dest framebuffer */
    if (edpy->blit_fb.width  != backing_width ||
        edpy->blit_fb.height != backing_height) {
        egl_fb_destroy(&edpy->blit_fb);
        egl_fb_setup_new_tex(&edpy->blit_fb, backing_width, backing_height);
    }
}

static void egl_scanout_texture(void *dg,
                                uint32_t backing_id,
                                DisplayGLTextureBorrower backing_borrower,
                                uint32_t x, uint32_t y,
                                uint32_t w, uint32_t h)
{
    bool backing_y_0_top;
    uint32_t backing_width;
    uint32_t backing_height;

    GLuint backing_texture = backing_borrower(backing_id, &backing_y_0_top,
                                              &backing_width, &backing_height);
    if (backing_texture) {
        egl_scanout_imported_texture(dg, backing_texture, backing_y_0_top,
                                     backing_width, backing_height);
    }
}

#ifdef CONFIG_GBM
static void egl_scanout_dmabuf(void *dg, QemuDmaBuf *dmabuf)
{
    egl_dmabuf_import_texture(dmabuf);
    if (!dmabuf->texture) {
        return;
    }

    egl_scanout_imported_texture(dg, dmabuf->texture,
                                 false, dmabuf->width, dmabuf->height);
}

static void egl_cursor_dmabuf(void *dg,
                              QemuDmaBuf *dmabuf, bool have_hot,
                              uint32_t hot_x, uint32_t hot_y)
{
    egl_dpy *edpy = dg;

    if (dmabuf) {
        egl_dmabuf_import_texture(dmabuf);
        if (!dmabuf->texture) {
            return;
        }
        egl_fb_setup_for_tex(&edpy->cursor_fb, dmabuf->width, dmabuf->height,
                             dmabuf->texture, false);
    } else {
        egl_fb_destroy(&edpy->cursor_fb);
    }
}

static void egl_cursor_position(void *dg,
                                uint32_t pos_x, uint32_t pos_y)
{
    egl_dpy *edpy = dg;

    edpy->pos_x = pos_x;
    edpy->pos_y = pos_y;
}

static void egl_release_dmabuf(void *dg, QemuDmaBuf *dmabuf)
{
    egl_dmabuf_release_texture(dmabuf);
}
#endif

static void egl_scanout_flush(DisplayChangeListener *dcl,
                              uint32_t x, uint32_t y,
                              uint32_t w, uint32_t h)
{
    egl_dpy *edpy = container_of(dcl, egl_dpy, dcl);

    if (!edpy->guest_fb.texture || !edpy->ds) {
        return;
    }
    assert(surface_format(edpy->ds) == PIXMAN_x8r8g8b8);

    if (edpy->cursor_fb.texture) {
        /* have cursor -> render using textures */
        egl_texture_blit(edpy->gls, &edpy->blit_fb, &edpy->guest_fb,
                         !edpy->y_0_top, false);
        egl_texture_blend(edpy->gls, &edpy->blit_fb, &edpy->cursor_fb,
                          false, !edpy->y_0_top, edpy->pos_x, edpy->pos_y,
                          1.0, 1.0);
    } else {
        /* no cursor -> use simple framebuffer blit */
        egl_fb_blit(&edpy->blit_fb, &edpy->guest_fb, edpy->y_0_top);
    }

    egl_fb_read(edpy->ds, &edpy->blit_fb);
    dpy_gfx_update(edpy->dcl.con, x, y, w, h);
}

static const DisplayGLOps dg_egl_ops = {
    .dpy_gl_ctx_create       = egl_create_context,
    .dpy_gl_ctx_destroy      = qemu_egl_destroy_context,
    .dpy_gl_ctx_make_current = qemu_egl_make_context_current,

    .dpy_gl_scanout_get_enabled = egl_scanout_get_enabled,
    .dpy_gl_scanout_disable     = egl_scanout_disable,
    .dpy_gl_scanout_texture     = egl_scanout_texture,
#ifdef CONFIG_GBM
    .dpy_gl_scanout_dmabuf      = egl_scanout_dmabuf,
    .dpy_gl_cursor_dmabuf       = egl_cursor_dmabuf,
    .dpy_gl_cursor_position     = egl_cursor_position,
    .dpy_gl_release_dmabuf      = egl_release_dmabuf,
#endif
};

static const DisplayChangeListenerOps dcl_egl_ops = {
    .dpy_name                = "egl-headless",
    .dpy_refresh             = egl_refresh,
    .dpy_gfx_update          = egl_gfx_update,
    .dpy_gfx_switch          = egl_gfx_switch,

    .dpy_gl_update           = egl_scanout_flush,
};

static void early_egl_headless_init(DisplayOptions *opts)
{
    display_opengl = 1;
}

static void egl_headless_init(DisplayState *ds, DisplayOptions *opts)
{
    DisplayGLMode mode = opts->has_gl ? opts->gl : DISPLAYGL_MODE_ON;
    QemuConsole *con;
    egl_dpy *edpy;
    int idx;

#ifdef CONFIG_GBM
    if (egl_rendernode_init(opts->u.egl_headless.rendernode, mode) < 0) {
        error_report("egl: render node init failed");
        exit(1);
    }
#else
    if (qemu_egl_init_dpy_surfaceless(mode)) {
        error_report("egl: display init failed");
        exit(1);
    }

    ctx = qemu_egl_init_ctx();
    if (!ctx) {
        error_report("egl: egl_init_ctx failed");
        exit(1);
    }
#endif

    register_displayglops(&dg_egl_ops);

    for (idx = 0;; idx++) {
        con = qemu_console_lookup_by_index(idx);
        if (!con || !qemu_console_is_graphic(con)) {
            break;
        }

        edpy = g_new0(egl_dpy, 1);
        edpy->dcl.con = con;
        edpy->dcl.ops = &dcl_egl_ops;
        edpy->gls = qemu_gl_init_shader();
        console_set_displayglcontext(con, edpy);
        register_displaychangelistener(&edpy->dcl);
    }
}

static QemuDisplay qemu_display_egl = {
    .type       = DISPLAY_TYPE_EGL_HEADLESS,
    .early_init = early_egl_headless_init,
    .init       = egl_headless_init,
};

static void register_egl(void)
{
    qemu_display_register(&qemu_display_egl);
}

type_init(register_egl);

module_dep("ui-opengl");
