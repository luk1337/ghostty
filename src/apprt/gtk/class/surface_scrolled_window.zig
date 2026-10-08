const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gtk_version = @import("../gtk_version.zig");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/i18n.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_surface_scrolled_window);

/// A wrapper widget that embeds a Surface inside a GtkScrolledWindow.
/// This provides scrollbar functionality for the terminal surface.
/// The surface property can be set during initialization or changed
/// dynamically via the surface property.
///
/// This is the leaf widget of a split tree, so it also provides the
/// Tilix-style split title bar (see `gtk-split-titlebar`).
pub const SurfaceScrolledWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhostttySurfaceScrolledWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        /// The 1-based position of this surface within its split tree,
        /// shown in the split title bar.
        pub const index = struct {
            pub const name = "index";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 1,
                    .minimum = 0,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        c_uint,
                        .{
                            .getter = getIndex,
                            .setter = setIndex,
                        },
                    ),
                },
            );
        };

        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        config: ?*Config = null,
        config_binding: ?*gobject.Binding = null,
        surface: ?*Surface = null,
        index: c_uint = 1,
        scrolled_window: *gtk.ScrolledWindow,
        title_button: *gtk.MenuButton,
        titlebar: *gtk.Widget,
        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        if (gtk_version.runtimeUntil(4, 20, 1)) self.disableKineticScroll();
    }

    fn disableKineticScroll(self: *Self) void {
        // Until gtk 4.20.1 trackpads have kinetic scrolling behavior regardless
        // of `Gtk.ScrolledWindow.kinetic_scrolling`. As a workaround, disable
        // EventControllerScroll.kinetic
        const controllers = self.private().scrolled_window.as(gtk.Widget).observeControllers();
        defer controllers.unref();
        var i: c_uint = 0;
        while (controllers.getObject(i)) |obj| : (i += 1) {
            defer obj.unref();
            const controller = gobject.ext.cast(gtk.EventControllerScroll, obj) orelse continue;
            var flags = controller.getFlags();
            flags.kinetic = false;
            controller.setFlags(flags);
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.disconnectSurfaceHandlers();

        if (priv.config_binding) |binding| {
            binding.unbind();
            binding.unref();
            priv.config_binding = null;
        }

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().surface,
        );
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }

    pub fn getIndex(self: *Self) c_uint {
        return self.private().index;
    }

    pub fn setIndex(self: *Self, index: c_uint) void {
        const priv = self.private();
        if (priv.index == index) return;
        priv.index = index;
        self.as(gobject.Object).notifyByPspec(properties.index.impl.param_spec);
    }

    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }

    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();

        if (surface_ == priv.surface) return;

        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);

        self.disconnectSurfaceHandlers();
        priv.surface = surface_;
    }

    fn closureScrollbarPolicy(
        _: *Self,
        config_: ?*Config,
    ) callconv(.c) gtk.PolicyType {
        const config = if (config_) |c| c.get() else return .automatic;
        return switch (config.scrollbar) {
            .never => .never,
            .system => .automatic,
        };
    }

    fn propSurface(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const scrolled_window = self.private().scrolled_window.as(gtk.ScrolledWindow);
        scrolled_window.setChild(if (priv.surface) |s| s.as(gtk.Widget) else null);

        // Unbind old config binding if it exists
        if (priv.config_binding) |binding| {
            binding.unbind();
            binding.unref();
            priv.config_binding = null;
        }

        // Expose the surface actions to our title bar menu, which isn't
        // a descendant of the surface.
        self.as(gtk.Widget).insertActionGroup(
            "surface",
            if (priv.surface) |s| s.getActionGroup() else null,
        );

        // Bind config from surface to our config property
        if (priv.surface) |surface| {
            const binding = surface.as(gobject.Object).bindProperty(
                properties.config.name,
                self.as(gobject.Object),
                properties.config.name,
                .{ .sync_create = true },
            );
            // Keep another ref, otherwise the binding would be freed and
            // our pointer become stale if the surface gets finalized.
            binding.ref();
            priv.config_binding = binding;

            // Dim the title bar when the surface isn't focused.
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
            propSurfaceFocused(surface, undefined, self);
        }
    }

    //---------------------------------------------------------------
    // Title bar

    fn disconnectSurfaceHandlers(self: *Self) void {
        const surface = self.private().surface orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            surface.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
    }

    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const titlebar = self.private().titlebar;
        if (surface.getFocused()) {
            titlebar.removeCssClass("unfocused");
        } else {
            titlebar.addCssClass("unfocused");
        }
    }

    fn closureTitlebarVisible(
        _: *Self,
        config_: ?*Config,
        is_split: c_int,
    ) callconv(.c) c_int {
        const config = config_ orelse return @intFromBool(false);
        return @intFromBool(Surface.shouldSplitTitlebarBeShown(
            config,
            is_split != 0,
        ));
    }

    fn closureComputedTitle(
        _: *Self,
        index: c_uint,
        title_: ?[*:0]const u8,
        title_override_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const title = std.mem.span(title_override_ orelse title_ orelse "Ghostty");
        const alloc = Application.default().allocator();
        const str = std.fmt.allocPrintSentinel(
            alloc,
            "{d}: {s}",
            .{ index, title },
            0,
        ) catch return glib.ext.dupeZ(u8, title);
        defer alloc.free(str);
        return glib.ext.dupeZ(u8, str);
    }

    fn closureZoomIcon(
        _: *Self,
        zoom: c_int,
    ) callconv(.c) ?[*:0]const u8 {
        return glib.ext.dupeZ(u8, if (zoom != 0)
            "window-restore-symbolic"
        else
            "window-maximize-symbolic");
    }

    fn closureZoomTooltip(
        _: *Self,
        zoom: c_int,
    ) callconv(.c) ?[*:0]const u8 {
        return glib.ext.dupeZ(u8, std.mem.span(if (zoom != 0)
            i18n._("Restore")
        else
            i18n._("Maximize")));
    }

    /// Make our surface the active surface of the split tree so that split
    /// actions triggered from the title bar target it.
    fn focusSurface(self: *Self) void {
        const surface = self.private().surface orelse return;
        const tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return;
        tree.focusSurface(surface);
    }

    fn titlebarPressed(
        gesture: *gtk.GestureClick,
        n_press: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        self.focusSurface();

        // Like Tilix, double clicking the title bar (outside of the title
        // menu and buttons) toggles zoom.
        if (n_press != 2) return;
        if (gesture.as(gtk.GestureSingle).getCurrentButton() != gdk.BUTTON_PRIMARY) return;
        const titlebar = gesture.as(gtk.EventController).getWidget() orelse return;
        if (titlebar.pick(x, y, .{})) |picked| {
            if (ext.getAncestor(gtk.Button, picked) != null) return;
        }
        _ = self.as(gtk.Widget).activateAction("split-tree.zoom", null);
    }

    fn titlebarDragPrepare(
        _: *gtk.DragSource,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const surface = self.private().surface orelse return null;
        if (surface.core() == null) return null;
        return surface.dragContentProvider();
    }

    fn titlebarDragBegin(
        src: *gtk.DragSource,
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        // Don't leave the title menu popover open while dragging.
        self.private().title_button.popdown();
        const surface = self.private().surface orelse return;
        surface.setDragIcon(src);
    }

    fn titlebarDragCancel(
        _: *gtk.DragSource,
        _: *gdk.Drag,
        reason: gdk.DragCancelReason,
        self: *Self,
    ) callconv(.c) c_int {
        const surface = self.private().surface orelse return 0;
        return @intFromBool(surface.dragCancelled(reason));
    }

    fn zoomClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.focusSurface();
        _ = self.as(gtk.Widget).activateAction("split-tree.zoom", null);
    }

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const surface = self.private().surface orelse return;
        surface.close();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "surface-scrolled-window",
                }),
            );

            // Bindings
            class.bindTemplateCallback("scrollbar_policy", &closureScrollbarPolicy);
            class.bindTemplateCallback("notify_surface", &propSurface);
            class.bindTemplateChildPrivate("scrolled_window", .{});
            class.bindTemplateChildPrivate("title_button", .{});
            class.bindTemplateChildPrivate("titlebar", .{});
            class.bindTemplateCallback("titlebar_visible", &closureTitlebarVisible);
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("zoom_icon", &closureZoomIcon);
            class.bindTemplateCallback("zoom_tooltip", &closureZoomTooltip);
            class.bindTemplateCallback("titlebar_pressed", &titlebarPressed);
            class.bindTemplateCallback("titlebar_drag_prepare", &titlebarDragPrepare);
            class.bindTemplateCallback("titlebar_drag_begin", &titlebarDragBegin);
            class.bindTemplateCallback("titlebar_drag_cancel", &titlebarDragCancel);
            class.bindTemplateCallback("zoom_clicked", &zoomClicked);
            class.bindTemplateCallback("close_clicked", &closeClicked);

            // Properties
            gobject.ext.ensureType(Surface);
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.index.impl,
                properties.surface.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
