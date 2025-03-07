#ifndef EGL_HELPERS_H
#define EGL_HELPERS_H

#include <epoxy/gl.h>
#include <epoxy/egl.h>
#ifdef CONFIG_GBM
#include <gbm.h>
#endif
#ifdef CONFIG_ANGLE
#include <EGL/eglext_angle.h>
#endif
#include "ui/console.h"
#include "ui/shader.h"

extern EGLDisplay *qemu_egl_display;
extern EGLConfig qemu_egl_config;
extern DisplayGLMode qemu_egl_mode;

typedef struct egl_fb {
    int width;
    int height;
    GLuint texture;
    GLenum texture_target;
    GLuint framebuffer;
    bool delete_texture;
} egl_fb;

void egl_fb_destroy(egl_fb *fb);
void egl_fb_setup_default(egl_fb *fb, int width, int height);
void egl_fb_setup_for_tex_target(egl_fb *fb, int width, int height,
                                 GLuint texture, GLenum target, bool delete);
void egl_fb_setup_for_tex(egl_fb *fb, int width, int height,
                          GLuint texture, bool delete);
void egl_fb_setup_new_tex_target(egl_fb *fb, int width, int height, GLenum target);
void egl_fb_setup_new_tex(egl_fb *fb, int width, int height);
void egl_fb_blit(egl_fb *dst, egl_fb *src, bool flip);
void egl_fb_read(DisplaySurface *dst, egl_fb *src);

void egl_texture_blit(QemuGLShader *gls, egl_fb *dst, egl_fb *src, bool flip, bool swap);
void egl_texture_blend(QemuGLShader *gls, egl_fb *dst, egl_fb *src, bool flip,
                       bool swap, int x, int y, double scale_x, double scale_y);

#ifdef CONFIG_GBM

extern int qemu_egl_rn_fd;
extern struct gbm_device *qemu_egl_rn_gbm_dev;
extern EGLContext qemu_egl_rn_ctx;

int egl_rendernode_init(const char *rendernode, DisplayGLMode mode);
int egl_get_fd_for_texture(uint32_t tex_id, EGLint *stride, EGLint *fourcc,
                           EGLuint64KHR *modifier);

void egl_dmabuf_import_texture(QemuDmaBuf *dmabuf);
void egl_dmabuf_release_texture(QemuDmaBuf *dmabuf);

#endif

EGLSurface qemu_egl_init_surface(EGLContext ectx, EGLNativeWindowType win);
EGLSurface qemu_egl_init_buffer_surface(EGLContext ectx, EGLenum buftype,
                                        EGLClientBuffer buffer, const EGLint *attrib_list);
bool qemu_egl_destroy_surface(EGLSurface surface);

int qemu_egl_init_dpy_cocoa(DisplayGLMode mode);
int qemu_egl_init_dpy_surfaceless(DisplayGLMode mode);

#if defined(CONFIG_X11) || defined(CONFIG_GBM)

int qemu_egl_init_dpy_x11(EGLNativeDisplayType dpy, DisplayGLMode mode);
int qemu_egl_init_dpy_mesa(EGLNativeDisplayType dpy, DisplayGLMode mode);

#endif

#if defined(CONFIG_ANGLE)

int qemu_egl_init_dpy_angle(DisplayGLMode mode);

#endif

EGLContext qemu_egl_init_ctx(void);
bool qemu_egl_has_dmabuf(void);

#endif /* EGL_HELPERS_H */
