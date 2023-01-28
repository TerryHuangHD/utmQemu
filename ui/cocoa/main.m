/*
 * QEMU Cocoa CG display driver
 *
 * Copyright (c) 2008 Mike Kronenberg
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#define GL_SILENCE_DEPRECATION

#include "qemu/osdep.h"

#include <crt_externs.h>

#include "qemu-common.h"
#include "ui/cocoa.h"
#include "ui/input.h"
#include "sysemu/sysemu.h"
#include "qapi/qapi-commands-block.h"

#ifdef CONFIG_EGL
#include "ui/egl-context.h"
#endif

static QEMUScreen screen;
static QemuCocoaAppController *appController;
static bool have_cocoa_ui;

static NSInteger cbchangecount = -1;
static QemuClipboardPeer cbpeer;
static QemuCocoaClipboard qemucb;
static QemuCocoaPasteboardTypeOwner *cbowner;

#ifdef CONFIG_OPENGL

static GLuint cursor_texture;
static bool gl_dirty;
static QEMUGLContext view_ctx;

#ifdef CONFIG_EGL
static EGLSurface egl_surface;
#endif

static bool cocoa_gl_is_compatible_dcl(DisplayGLCtx *dgc,
                                       DisplayChangeListener *dcl);

static QEMUGLContext cocoa_gl_create_context(DisplayGLCtx *dgc,
                                             QEMUGLParams *params);

static void cocoa_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx);

static int cocoa_gl_make_context_current(DisplayGLCtx *dgc, QEMUGLContext ctx);

static const DisplayGLCtxOps dgc_ops = {
    .dpy_gl_ctx_is_compatible_dcl = cocoa_gl_is_compatible_dcl,
    .dpy_gl_ctx_create            = cocoa_gl_create_context,
    .dpy_gl_ctx_destroy           = cocoa_gl_destroy_context,
    .dpy_gl_ctx_make_current      = cocoa_gl_make_context_current,
};

static DisplayGLCtx dgc = {
    .ops = &dgc_ops,
};

#endif

/*
 * The startup process for the OSX/Cocoa UI is complicated, because
 * OSX insists that the UI runs on the initial main thread, and so we
 * need to start a second thread which runs qemu_main_loop():
 *
 * Initial thread:                    2nd thread:
 * in main():
 *  qemu_init()
 *  create main loop thread
 *  enter OSX run loop                call qemu_main_loop()
 */

static void *call_qemu_main_loop(void *opaque)
{
    COCOA_DEBUG("Second thread: calling qemu_main_loop()\n");
    qemu_mutex_lock_iothread();
    qemu_main_loop();
    COCOA_DEBUG("Second thread: qemu_main_loop() returned, exiting\n");
    qemu_cleanup();
    qkbd_state_free(screen.kbd);
    [cbowner release];
    CGImageRelease(screen.cursor_cgimage);
#ifdef CONFIG_OPENGL
    qemu_gl_fini_shader(dgc.gls);
    if (view_ctx) {
        cocoa_gl_destroy_context(&dgc, view_ctx);
    }
#endif
    exit(0);
}

@interface QemuApplication : NSApplication
@end

@implementation QemuApplication
- (void)sendEvent:(NSEvent *)event
{
    COCOA_DEBUG("QemuApplication: sendEvent\n");
    if (![[appController cocoaView] handleEvent:event]) {
        [super sendEvent: event];
    }
}
@end

static void create_initial_menus(void)
{
    // Add menus
    NSMenu      *menu;
    NSMenuItem  *menuItem;

    [NSApp setMainMenu:[[NSMenu alloc] init]];
    [NSApp setServicesMenu:[[NSMenu alloc] initWithTitle:@"Services"]];

    // Application menu
    menu = [[NSMenu alloc] initWithTitle:@""];
    // [menu addItemWithTitle:@"About QEMU" action:@selector(do_about_menu_item:) keyEquivalent:@""]; // About QEMU
    // [menu addItem:[NSMenuItem separatorItem]]; //Separator
    menuItem = [menu addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
    [menuItem setSubmenu:[NSApp servicesMenu]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Hide Windows" action:@selector(hide:) keyEquivalent:@"h"]; //Hide QEMU
    menuItem = (NSMenuItem *)[menu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"]; // Hide Others
    [menuItem setKeyEquivalentModifierMask:(NSEventModifierFlagOption|NSEventModifierFlagCommand)];
    [menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""]; // Show All
    [menu addItem:[NSMenuItem separatorItem]]; //Separator
    [menu addItemWithTitle:@"Quit Windows" action:@selector(terminate:) keyEquivalent:@"q"];
    menuItem = [[NSMenuItem alloc] initWithTitle:@"Apple" action:nil keyEquivalent:@""];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
    [NSApp performSelector:@selector(setAppleMenu:) withObject:menu]; // Workaround (this method is private since 10.4+)

    // Machine menu
    menu = [[NSMenu alloc] initWithTitle: @"Machine"];
    [menu setAutoenablesItems: NO];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Pause" action: @selector(pauseQEMU:) keyEquivalent: @""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle: @"Resume" action: @selector(resumeQEMU:) keyEquivalent: @""] autorelease];
    [menu addItem: menuItem];
    [menuItem setEnabled: NO];
    [menu addItem: [NSMenuItem separatorItem]];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Reset" action: @selector(restartQEMU:) keyEquivalent: @""] autorelease]];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Power Down" action: @selector(powerDownQEMU:) keyEquivalent: @""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle: @"Machine" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    // [[NSApp mainMenu] addItem:menuItem];

    // View menu
    menu = [[NSMenu alloc] initWithTitle:@"View"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Enter Fullscreen" action:@selector(doToggleFullScreen:) keyEquivalent:@"f"] autorelease]]; // Fullscreen
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Zoom To Fit" action:@selector(zoomToFit:) keyEquivalent:@""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    // [[NSApp mainMenu] addItem:menuItem];

    // Speed menu
    menu = [[NSMenu alloc] initWithTitle:@"Speed"];

    // Add the rest of the Speed menu items
    int p, percentage, throttle_pct;
    for (p = 10; p >= 0; p--)
    {
        percentage = p * 10 > 1 ? p * 10 : 1; // prevent a 0% menu item

        menuItem = [[[NSMenuItem alloc]
                   initWithTitle: [NSString stringWithFormat: @"%d%%", percentage] action:@selector(adjustSpeed:) keyEquivalent:@""] autorelease];

        if (percentage == 100) {
            [menuItem setState: NSControlStateValueOn];
        }

        /* Calculate the throttle percentage */
        throttle_pct = -1 * percentage + 100;

        [menuItem setTag: throttle_pct];
        [menu addItem: menuItem];
    }
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Speed" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    // [[NSApp mainMenu] addItem:menuItem];

    // Window menu
    menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"] autorelease]]; // Miniaturize
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
    // [NSApp setWindowsMenu:menu];

    // Help menu
    menu = [[NSMenu alloc] initWithTitle:@"Help"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"QEMU Documentation" action:@selector(showQEMUDoc:) keyEquivalent:@"?"] autorelease]]; // QEMU Help
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    // [[NSApp mainMenu] addItem:menuItem];
}

/* Returns a name for a given console */
static NSString * getConsoleName(QemuConsole * console)
{
    g_autofree char *label = qemu_console_get_label(console);

    return [NSString stringWithUTF8String:label];
}

/* Add an entry to the View menu for each console */
static void add_console_menu_entries(void)
{
    NSMenu *menu;
    NSMenuItem *menuItem;
    size_t index;

    menu = [[[NSApp mainMenu] itemWithTitle:@"View"] submenu];

    [menu addItem:[NSMenuItem separatorItem]];

    for (index = 0; index < screen.listeners_count; index++) {
        menuItem = [[[NSMenuItem alloc] initWithTitle: getConsoleName(screen.listeners[index].dcl.con)
                                               action: @selector(displayConsole:) keyEquivalent: @""] autorelease];
        [menuItem setTag: index];
        [menu addItem: menuItem];
    }
}

/* Make menu items for all removable devices.
 * Each device is given an 'Eject' and 'Change' menu item.
 */
static void addRemovableDevicesMenuItems(void)
{
    NSMenu *menu;
    NSMenuItem *menuItem;
    BlockInfoList *currentDevice, *pointerToFree;
    NSString *deviceName;

    currentDevice = qmp_query_block(NULL);
    pointerToFree = currentDevice;

    menu = [[[NSApp mainMenu] itemWithTitle:@"Machine"] submenu];

    // Add a separator between related groups of menu items
    [menu addItem:[NSMenuItem separatorItem]];

    // Set the attributes to the "Removable Media" menu item
    NSString *titleString = @"Removable Media";
    NSMutableAttributedString *attString=[[NSMutableAttributedString alloc] initWithString:titleString];
    NSColor *newColor = [NSColor blackColor];
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    NSFont *font = [fontManager fontWithFamily:@"Helvetica"
                                          traits:NSBoldFontMask|NSItalicFontMask
                                          weight:0
                                            size:14];
    [attString addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, [titleString length])];
    [attString addAttribute:NSForegroundColorAttributeName value:newColor range:NSMakeRange(0, [titleString length])];
    [attString addAttribute:NSUnderlineStyleAttributeName value:[NSNumber numberWithInt: 1] range:NSMakeRange(0, [titleString length])];

    // Add the "Removable Media" menu item
    menuItem = [NSMenuItem new];
    [menuItem setAttributedTitle: attString];
    [menuItem setEnabled: NO];
    [menu addItem: menuItem];

    /* Loop through all the block devices in the emulator */
    while (currentDevice) {
        deviceName = [[NSString stringWithFormat: @"%s", currentDevice->value->device] retain];

        if(currentDevice->value->removable) {
            menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"Change %s...", currentDevice->value->device]
                                                  action: @selector(changeDeviceMedia:)
                                           keyEquivalent: @""];
            [menu addItem: menuItem];
            [menuItem setRepresentedObject: deviceName];
            [menuItem autorelease];

            menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"Eject %s", currentDevice->value->device]
                                                  action: @selector(ejectDeviceMedia:)
                                           keyEquivalent: @""];
            [menu addItem: menuItem];
            [menuItem setRepresentedObject: deviceName];
            [menuItem autorelease];
        }
        currentDevice = currentDevice->next;
    }
    qapi_free_BlockInfoList(pointerToFree);
}

static void cocoa_mouse_mode_change_notify(Notifier *notifier, void *data)
{
    static bool shared_is_absolute;

    qatomic_set(&shared_is_absolute, qemu_input_is_absolute());

    dispatch_async(dispatch_get_main_queue(), ^{
        bool is_absolute = qatomic_read(&shared_is_absolute);
        if (is_absolute == [[appController cocoaView] isAbsoluteEnabled]) {
            return;
        }

        if (is_absolute && [[appController cocoaView] isMouseGrabbed]) {
            [[appController cocoaView] ungrabMouse];
        }
        [[appController cocoaView] setAbsoluteEnabled:is_absolute];
    });
}

static Notifier mouse_mode_change_notifier = {
    .notify = cocoa_mouse_mode_change_notify
};

static void cocoa_clipboard_notify(Notifier *notifier, void *data);
static void cocoa_clipboard_request(QemuClipboardInfo *info,
                                    QemuClipboardType type);

static QemuClipboardPeer cbpeer = {
    .name = "cocoa",
    .notifier = { .notify = cocoa_clipboard_notify },
    .request = cocoa_clipboard_request
};

static void cocoa_clipboard_update_info(QemuClipboardInfo *info)
{
    if (info->owner == &cbpeer || info->selection != QEMU_CLIPBOARD_SELECTION_CLIPBOARD) {
        return;
    }

    if (info != qemucb.info) {
        NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
        qemu_clipboard_info_unref(qemucb.info);
        qemucb.info = qemu_clipboard_info_ref(info);
        cbchangecount = [[NSPasteboard generalPasteboard] declareTypes:@[NSPasteboardTypeString] owner:cbowner];
        [pool release];
    }

    qemu_event_set(&qemucb.event);
}

static void cocoa_clipboard_notify(Notifier *notifier, void *data)
{
    QemuClipboardNotify *notify = data;

    switch (notify->type) {
    case QEMU_CLIPBOARD_UPDATE_INFO:
        cocoa_clipboard_update_info(notify->info);
        return;
    case QEMU_CLIPBOARD_RESET_SERIAL:
        /* ignore */
        return;
    }
}

static void cocoa_clipboard_request(QemuClipboardInfo *info,
                                    QemuClipboardType type)
{
    NSData *text;

    switch (type) {
    case QEMU_CLIPBOARD_TYPE_TEXT:
        text = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypeString];
        if (text) {
            qemu_clipboard_set_data(&cbpeer, info, type,
                                    [text length], [text bytes], true);
            [text release];
        }
        break;
    default:
        break;
    }
}

int main(int argc, char **argv, char **envp)
{
    QemuThread main_thread;

    COCOA_DEBUG("Entered main()\n");

    /* Takes iothread lock.  */
    qemu_init(argc, argv, envp);
    if (!have_cocoa_ui) {
         qemu_main_loop();
         qemu_cleanup();
         return 0;
    }

    qemu_mutex_unlock_iothread();
    qemu_thread_create(&main_thread, "qemu_main_loop", call_qemu_main_loop,
                       NULL, QEMU_THREAD_DETACHED);

    // Start the main event loop
    COCOA_DEBUG("Main thread: entering OSX run loop\n");
    [NSApp run];
    COCOA_DEBUG("Main thread: left OSX run loop, exiting\n");

    return 0;
}



#pragma mark qemu
static void cocoa_update(DisplayChangeListener *dcl,
                         int x, int y, int w, int h)
{
    DisplaySurface *updated = screen.surface;

    if (container_of(dcl, CocoaListener, dcl) != screen.active_listener) {
        return;
    }

    COCOA_DEBUG("qemu_cocoa: cocoa_update\n");

    dispatch_async(dispatch_get_main_queue(), ^{
        qemu_mutex_lock(&screen.draw_mutex);
        if (updated != screen.surface) {
            qemu_mutex_unlock(&screen.draw_mutex);
            return;
        }
        int full_height = surface_height(screen.surface);
        qemu_mutex_unlock(&screen.draw_mutex);

        CGFloat d = [[appController cocoaView] frame].size.height / full_height;
        NSRect rect = NSMakeRect(x * d, (full_height - y - h) * d, w * d, h * d);
        [[appController cocoaView] setNeedsDisplayInRect:rect];
    });
}

static void cocoa_switch(DisplayChangeListener *dcl,
                         DisplaySurface *new_surface)
{
    COCOA_DEBUG("qemu_cocoa: cocoa_switch\n");

    if (container_of(dcl, CocoaListener, dcl) != screen.active_listener) {
        return;
    }

    qemu_mutex_lock(&screen.draw_mutex);
    screen.surface = new_surface;
    qemu_mutex_unlock(&screen.draw_mutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        qemu_mutex_lock(&screen.draw_mutex);
        int w = surface_width(screen.surface);
        int h = surface_height(screen.surface);
        qemu_mutex_unlock(&screen.draw_mutex);

        [[appController cocoaView] updateScreenWidth:w height:h];
    });
}

static void cocoa_refresh(DisplayChangeListener *dcl)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    COCOA_DEBUG("qemu_cocoa: cocoa_refresh\n");

    if (container_of(dcl, CocoaListener, dcl) != screen.active_listener) {
        return;
    }

    graphic_hw_update(dcl->con);

    if (cbchangecount != [[NSPasteboard generalPasteboard] changeCount]) {
        qemu_clipboard_info_unref(qemucb.info);
        qemucb.info = qemu_clipboard_info_new(&cbpeer, QEMU_CLIPBOARD_SELECTION_CLIPBOARD);
        if ([[NSPasteboard generalPasteboard] availableTypeFromArray:@[NSPasteboardTypeString]]) {
            qemucb.info->types[QEMU_CLIPBOARD_TYPE_TEXT].available = true;
        }
        qemu_clipboard_update(qemucb.info);
        cbchangecount = [[NSPasteboard generalPasteboard] changeCount];
        qemu_event_set(&qemucb.event);
    }

    [pool release];
}

static void cocoa_mouse_set(DisplayChangeListener *dcl, int x, int y, int on)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    qemu_mutex_lock(&screen.draw_mutex);
    int full_height = surface_height(screen.surface);
    int old_x = listener->mouse_x;
    int old_y = listener->mouse_y;
    listener->mouse_x = x;
    listener->mouse_y = y;
    listener->mouse_on = on;
    qemu_mutex_unlock(&screen.draw_mutex);

    if (listener == screen.active_listener && screen.cursor_cgimage) {
        size_t cursor_width = CGImageGetWidth(screen.cursor_cgimage);
        size_t cursor_height = CGImageGetHeight(screen.cursor_cgimage);

        dispatch_async(dispatch_get_main_queue(), ^{
            [[appController cocoaView] setNeedsDisplayForCursorX:old_x
                                                               y:old_y
                                                           width:cursor_width
                                                          height:cursor_height
                                                    screenHeight:full_height];

            [[appController cocoaView] setNeedsDisplayForCursorX:x
                                                               y:y
                                                           width:cursor_width
                                                          height:cursor_height
                                                    screenHeight:full_height];
        });
    }
}

static void cocoa_cursor_update()
{
    CGImageRef old_image = screen.cursor_cgimage;
    CGImageRef new_image;
    CocoaListener *active_listener = screen.active_listener;

    if (active_listener->cursor) {
        CGDataProviderRef provider = CGDataProviderCreateWithData(
            NULL,
            active_listener->cursor->data,
            active_listener->cursor->width * active_listener->cursor->height * 4,
            NULL
        );

        new_image = CGImageCreate(
            active_listener->cursor->width, //width
            active_listener->cursor->height, //height
            8, //bitsPerComponent
            32, //bitsPerPixel
            active_listener->cursor->width * 4, //bytesPerRow
            CGColorSpaceCreateWithName(kCGColorSpaceSRGB), //colorspace
            kCGBitmapByteOrder32Little | kCGImageAlphaFirst, //bitmapInfo
            provider, //provider
            NULL, //decode
            0, //interpolate
            kCGRenderingIntentDefault //intent
        );

        CGDataProviderRelease(provider);
    } else {
        new_image = NULL;
    }

    qemu_mutex_lock(&screen.draw_mutex);
    screen.cursor_cgimage = new_image;
    qemu_mutex_unlock(&screen.draw_mutex);

    CGImageRelease(old_image);
}

static void cocoa_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->cursor = cursor;

    if (listener == screen.active_listener) {
        int full_height = surface_height(screen.surface);
        int width = cursor->width;
        int height = cursor->height;
        int x = listener->mouse_x;
        int y = listener->mouse_y;
        size_t old_width;
        size_t old_height;

        if (screen.cursor_cgimage) {
            old_width = CGImageGetWidth(screen.cursor_cgimage);
            old_height = CGImageGetHeight(screen.cursor_cgimage);
        } else {
            old_width = 0;
            old_height = 0;
        }

        cocoa_cursor_update();

        dispatch_async(dispatch_get_main_queue(), ^{
            CGFloat d = [[appController cocoaView] frame].size.height / full_height;
            NSRect rect;

            rect.origin.x = d * x;
            rect.origin.y = d * (full_height - y - old_height);
            rect.size.width = d * old_width;
            rect.size.height = d * old_height;
            [[appController cocoaView] setNeedsDisplayInRect:rect];

            rect.size.width = d * width;
            rect.size.height = d * height;
            [[appController cocoaView] setNeedsDisplayInRect:rect];
        });
    }
}

static const DisplayChangeListenerOps dcl_ops = {
    .dpy_name          = "cocoa",
    .dpy_gfx_update = cocoa_update,
    .dpy_gfx_switch = cocoa_switch,
    .dpy_refresh = cocoa_refresh,
    .dpy_mouse_set = cocoa_mouse_set,
    .dpy_cursor_define = cocoa_cursor_define,
};

#ifdef CONFIG_OPENGL

static void with_view_ctx(CodeBlock block)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglMakeCurrent(qemu_egl_display, egl_surface, egl_surface, view_ctx);
        block();
        return;
    }
#endif

    [(NSOpenGLContext *)view_ctx lock];
    [(NSOpenGLContext *)view_ctx makeCurrentContext];
    block();
    [(NSOpenGLContext *)view_ctx unlock];
}

static NSOpenGLPixelFormat *cocoa_gl_create_ns_pixel_format(int bpp)
{
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion4_1Core,
        NSOpenGLPFAColorSize,
        bpp,
        NSOpenGLPFADoubleBuffer,
        0,
    };

    return [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
}

static int cocoa_gl_make_context_current(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        EGLSurface current_surface = ctx == EGL_NO_CONTEXT ? EGL_NO_SURFACE : egl_surface;
        return eglMakeCurrent(qemu_egl_display, current_surface, current_surface, ctx);
    }
#endif

    if (ctx) {
        [(NSOpenGLContext *)ctx makeCurrentContext];
    } else {
        [NSOpenGLContext clearCurrentContext];
    }

    return 0;
}

static QEMUGLContext cocoa_gl_create_context(DisplayGLCtx *dgc,
                                             QEMUGLParams *params)
{
    NSOpenGLPixelFormat *format;
    NSOpenGLContext *ctx;
    int bpp;

#ifdef CONFIG_EGL
    if (egl_surface) {
        eglMakeCurrent(qemu_egl_display, egl_surface, egl_surface, view_ctx);
        return qemu_egl_create_context(dgc, params);
    }
#endif

    bpp = PIXMAN_FORMAT_BPP(surface_format(screen.surface));
    format = cocoa_gl_create_ns_pixel_format(bpp);
    ctx = [[NSOpenGLContext alloc] initWithFormat:format shareContext:view_ctx];
    [format release];

    return (QEMUGLContext)ctx;
}

static void cocoa_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglDestroyContext(qemu_egl_display, ctx);
        return;
    }
#endif

    [(NSOpenGLContext *)ctx release];
}

static void cocoa_gl_flush()
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglSwapBuffers(qemu_egl_display, egl_surface);
        return;
    }
#endif

    [[NSOpenGLContext currentContext] flushBuffer];

    dispatch_async(dispatch_get_main_queue(), ^{
        [(NSOpenGLContext *)view_ctx update];
    });
}

static void cocoa_gl_update(DisplayChangeListener *dcl,
                            int x, int y, int w, int h)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    if (listener != screen.active_listener) {
        return;
    }

    with_view_ctx(^{
        surface_gl_update_texture(dgc.gls, screen.surface, x, y, w, h);
        gl_dirty = true;
    });
}

static void cocoa_gl_cursor_render()
{
    if (!screen.active_listener->mouse_on) {
        return;
    }

    QemuCocoaView *cocoaView = [appController cocoaView];
    NSSize size = [cocoaView convertSizeToBacking:[cocoaView frame].size];
    CGFloat d = size.height / surface_height(screen.surface);
    CocoaListener *active_listener = screen.active_listener;

    glViewport(
        d * active_listener->mouse_x,
        size.height - d * (active_listener->mouse_y + active_listener->cursor->height),
        d * active_listener->cursor->width,
        d * active_listener->cursor->height
    );
    glBindTexture(GL_TEXTURE_2D, cursor_texture);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    qemu_gl_run_texture_blit(dgc.gls, false, false);
    glDisable(GL_BLEND);
}

static void cocoa_gl_switch(DisplayChangeListener *dcl,
                            DisplaySurface *new_surface)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    if (listener != screen.active_listener) {
        return;
    }

    with_view_ctx(^{
        surface_gl_destroy_texture(dgc.gls, screen.surface);
        surface_gl_create_texture(dgc.gls, new_surface);
    });

    cocoa_switch(dcl, new_surface);
    gl_dirty = true;
}

static void cocoa_gl_refresh(DisplayChangeListener *dcl)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    if (listener != screen.active_listener) {
        return;
    }

    cocoa_refresh(dcl);

    if (gl_dirty) {
        gl_dirty = false;

        with_view_ctx(^{
            QemuCocoaView *view = [appController cocoaView];
            NSSize size = [view convertSizeToBacking:[view frame].size];

            if (listener->gl_scanout_borrow) {
                bool y0_top;
                GLint texture =
                    listener->gl_scanout_borrow(listener->gl_scanout_id,
                                                &y0_top, NULL, NULL);

                glBindFramebuffer(GL_FRAMEBUFFER_EXT, 0);
                glViewport(0, 0, size.width, size.height);
                glBindTexture(GL_TEXTURE_2D, texture);
                qemu_gl_run_texture_blit(dgc.gls, y0_top, false);
            } else {
                surface_gl_setup_viewport(dgc.gls, screen.surface,
                                          size.width, size.height);
                glBindTexture(GL_TEXTURE_2D, screen.surface->texture);
                surface_gl_render_texture(dgc.gls, screen.surface);
            }

            cocoa_gl_cursor_render();
            cocoa_gl_flush();
        });
    }
}

static void cocoa_gl_scanout_disable(DisplayChangeListener *dcl)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->gl_scanout_borrow = NULL;

    if (listener == screen.active_listener) {
        gl_dirty = screen.surface != NULL;
    }
}

static void cocoa_gl_cursor_update()
{
    if (screen.active_listener->cursor) {
        with_view_ctx(^{
            glBindTexture(GL_TEXTURE_2D, cursor_texture);
            glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT,
                          screen.active_listener->cursor->width);
            glTexImage2D(GL_TEXTURE_2D, 0,
                         epoxy_is_desktop_gl() ? GL_RGBA : GL_BGRA,
                         screen.active_listener->cursor->width,
                         screen.active_listener->cursor->height,
                         0, GL_BGRA, GL_UNSIGNED_BYTE,
                         screen.active_listener->cursor->data);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        });
    }

    gl_dirty = true;
}

static void cocoa_gl_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->cursor = cursor;

    if (listener == screen.active_listener) {
        cocoa_gl_cursor_update();
    }
}

static void cocoa_gl_scanout_texture(DisplayChangeListener *dcl,
                                     uint32_t backing_id,
                                     DisplayGLTextureBorrower backing_borrow,
                                     uint32_t x, uint32_t y,
                                     uint32_t w, uint32_t h)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->gl_scanout_id = backing_id;
    listener->gl_scanout_borrow = backing_borrow;
    gl_dirty = true;
}

static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,
                                   uint32_t x, uint32_t y,
                                   uint32_t w, uint32_t h)
{
    if (container_of(dcl, CocoaListener, dcl) == screen.active_listener) {
        gl_dirty = true;
    }
}

static void cocoa_gl_mouse_set(DisplayChangeListener *dcl, int x, int y, int on)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->mouse_x = x;
    listener->mouse_y = y;
    listener->mouse_on = on;

    if (listener == screen.active_listener) {
        gl_dirty = true;
    }
}

static const DisplayChangeListenerOps dcl_gl_ops = {
    .dpy_name               = "cocoa-gl",
    .dpy_gfx_update         = cocoa_gl_update,
    .dpy_gfx_switch         = cocoa_gl_switch,
    .dpy_gfx_check_format   = console_gl_check_format,
    .dpy_refresh            = cocoa_gl_refresh,
    .dpy_mouse_set          = cocoa_gl_mouse_set,
    .dpy_cursor_define      = cocoa_gl_cursor_define,

    .dpy_gl_scanout_disable = cocoa_gl_scanout_disable,
    .dpy_gl_scanout_texture = cocoa_gl_scanout_texture,
    .dpy_gl_update          = cocoa_gl_scanout_flush,
};

static bool cocoa_gl_is_compatible_dcl(DisplayGLCtx *dgc,
                                       DisplayChangeListener *dcl)
{
    return dcl->ops == &dcl_gl_ops;
}

#endif

void cocoa_listener_select(size_t index)
{
    DisplaySurface *new_surface;

    if (index >= screen.listeners_count) {
        return;
    }

    qemu_mutex_lock(&screen.draw_mutex);
    screen.active_listener = &screen.listeners[index];
    qemu_mutex_unlock(&screen.draw_mutex);

    new_surface = qemu_console_surface(screen.active_listener->dcl.con);
    qkbd_state_lift_all_keys(screen.kbd);
    qkbd_state_free(screen.kbd);
    screen.kbd = qkbd_state_init(screen.active_listener->dcl.con);

    if (display_opengl) {
#ifdef CONFIG_OPENGL
        cocoa_gl_cursor_update();
        cocoa_gl_switch(&screen.active_listener->dcl, new_surface);
#else
        g_assert_not_reached();
#endif
    } else {
        cocoa_cursor_update();
        cocoa_switch(&screen.active_listener->dcl, new_surface);
    }
}

static void cocoa_display_early_init(DisplayOptions *o)
{
    assert(o->type == DISPLAY_TYPE_COCOA);
    if (o->has_gl && o->gl) {
        display_opengl = 1;
    }
}

static void cocoa_display_init(DisplayState *ds, DisplayOptions *opts)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    ProcessSerialNumber psn = { 0, kCurrentProcess };
    QemuCocoaView *cocoaView;
    const DisplayChangeListenerOps *ops;
    size_t index;

    COCOA_DEBUG("qemu_cocoa: cocoa_display_init\n");
    have_cocoa_ui = 1;

    // Pull this console process up to being a fully-fledged graphical
    // app with a menubar and Dock icon
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);

    [QemuApplication sharedApplication];

    // Create an Application controller
    appController = [[QemuCocoaAppController alloc] initWithScreen:&screen];
    cocoaView = [appController cocoaView];
    [NSApp setDelegate:appController];

    qemu_mutex_init(&screen.draw_mutex);

    if (display_opengl) {
#ifdef CONFIG_OPENGL
        if (opts->gl == DISPLAYGL_MODE_ES) {
#ifdef CONFIG_EGL
            if (qemu_egl_init_dpy_cocoa(DISPLAYGL_MODE_ES)) {
                exit(1);
            }
            view_ctx = qemu_egl_init_ctx();
            if (!view_ctx) {
                exit(1);
            }
            [cocoaView setWantsLayer:YES];
            egl_surface = qemu_egl_init_surface(view_ctx, [cocoaView layer]);
            if (!egl_surface) {
                exit(1);
            }
#else
            error_report("OpenGLES without EGL is not supported - exiting");
            exit(1);
#endif
        } else {
            NSOpenGLPixelFormat *format = cocoa_gl_create_ns_pixel_format(32);
            NSOpenGLView *view = [[NSOpenGLView alloc] initWithFrame:[cocoaView frame]
                                                         pixelFormat:format];
            [format release];
            [cocoaView addSubview:view];
            view_ctx = [view openGLContext];
            [view release];
#ifdef CONFIG_EGL
            egl_surface = EGL_NO_SURFACE;
#endif
            cocoa_gl_make_context_current(&dgc, view_ctx);
        }

        dgc.gls = qemu_gl_init_shader();
        glGenTextures(1, &cursor_texture);

        // register vga output callbacks
        ops = &dcl_gl_ops;
#else
        error_report("OpenGL is not enabled - exiting");
        exit(1);
#endif
    } else {
        // register vga output callbacks
        ops = &dcl_ops;
    }

    while (qemu_console_lookup_by_index(screen.listeners_count)) {
        screen.listeners_count++;
    }

    if (screen.listeners_count) {
        QemuConsole *con = qemu_console_lookup_first_graphic_console();
        screen.listeners = g_new0(CocoaListener, screen.listeners_count);
        screen.active_listener = screen.listeners + qemu_console_get_index(con);

        for (index = 0; index < screen.listeners_count; index++) {
            screen.listeners[index].dcl.con = qemu_console_lookup_by_index(index);
            screen.listeners[index].dcl.ops = ops;

            if (display_opengl) {
#ifdef CONFIG_OPENGL
                qemu_console_set_display_gl_ctx(screen.listeners[index].dcl.con,
                                                &dgc);
#else
                g_assert_not_reached();
#endif
            }

            // register vga output callbacks
            register_displaychangelistener(&screen.listeners[index].dcl);
        }

        screen.kbd = qkbd_state_init(screen.active_listener->dcl.con);
    }

    qemu_add_mouse_mode_change_notifier(&mouse_mode_change_notifier);
    [cocoaView setAbsoluteEnabled:qemu_input_is_absolute()];

    create_initial_menus();

    /*
     * Create the menu entries which depend on QEMU state (for consoles
     * and removeable devices). These make calls back into QEMU functions,
     * which is OK because at this point we know that the second thread
     * holds the iothread lock and is synchronously waiting for us to
     * finish.
     */
    add_console_menu_entries();
    addRemovableDevicesMenuItems();

    qemu_event_init(&qemucb.event, false);
    cbowner = [[QemuCocoaPasteboardTypeOwner alloc] initWith:&qemucb];

    if (opts->has_full_screen && opts->full_screen) {
        [[cocoaView window] toggleFullScreen: nil];
    }
    if (opts->u.cocoa.has_full_grab && opts->u.cocoa.full_grab) {
        [cocoaView setFullGrab: nil];
    }

    if (opts->has_show_cursor) {
        screen.cursor_show = opts->show_cursor;
    }
    if (opts->u.cocoa.has_swap_opt_cmd) {
        screen.swap_opt_cmd = opts->u.cocoa.swap_opt_cmd;
    }

    if (opts->u.cocoa.has_left_command_key) {
        screen.left_command_key_disabled = opts->u.cocoa.left_command_key;
    }

    [cocoaView updateUIInfo];
    qemu_clipboard_peer_register(&cbpeer);
    [pool release];
}

static QemuDisplay qemu_display_cocoa = {
    .type       = DISPLAY_TYPE_COCOA,
    .early_init = cocoa_display_early_init,
    .init       = cocoa_display_init,
};

static void register_cocoa(void)
{
    qemu_display_register(&qemu_display_cocoa);
}

type_init(register_cocoa);

#ifdef CONFIG_OPENGL
module_dep("ui-opengl");
#endif
