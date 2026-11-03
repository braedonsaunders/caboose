use super::Server;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use wayland_client::globals::{registry_queue_init, GlobalList, GlobalListContents};
use wayland_client::protocol::{
    wl_buffer, wl_callback, wl_compositor, wl_data_device, wl_data_offer, wl_data_device_manager, wl_data_source, wl_keyboard,
    wl_output, wl_pointer, wl_registry, wl_seat, wl_shm, wl_shm_pool, wl_subcompositor, wl_subsurface, wl_surface,
    wl_touch,
};
use wayland_client::{Connection, Dispatch, EventQueue, Proxy, QueueHandle, WEnum};
use wayland_protocols::wp::content_type::v1::client::{wp_content_type_manager_v1, wp_content_type_v1};
use wayland_protocols::wp::cursor_shape::v1::client::{wp_cursor_shape_device_v1, wp_cursor_shape_manager_v1};
use wayland_protocols::wp::fractional_scale::v1::client::{wp_fractional_scale_manager_v1, wp_fractional_scale_v1};
use wayland_protocols::wp::idle_inhibit::zv1::client::{zwp_idle_inhibit_manager_v1, zwp_idle_inhibitor_v1};
use wayland_protocols::wp::keyboard_shortcuts_inhibit::zv1::client::{
    zwp_keyboard_shortcuts_inhibit_manager_v1, zwp_keyboard_shortcuts_inhibitor_v1,
};
use wayland_protocols::wp::linux_dmabuf::zv1::client::{
    zwp_linux_buffer_params_v1, zwp_linux_dmabuf_feedback_v1, zwp_linux_dmabuf_v1,
};
use wayland_protocols::wp::pointer_constraints::zv1::client::{
    zwp_confined_pointer_v1, zwp_locked_pointer_v1, zwp_pointer_constraints_v1,
};
use wayland_protocols::wp::pointer_gestures::zv1::client::{
    zwp_pointer_gesture_hold_v1, zwp_pointer_gesture_pinch_v1, zwp_pointer_gesture_swipe_v1, zwp_pointer_gestures_v1,
};
use wayland_protocols::wp::presentation_time::client::{wp_presentation, wp_presentation_feedback};
use wayland_protocols::wp::primary_selection::zv1::client::{
    zwp_primary_selection_device_manager_v1, zwp_primary_selection_device_v1, zwp_primary_selection_offer_v1,
    zwp_primary_selection_source_v1,
};
use wayland_protocols::wp::relative_pointer::zv1::client::{zwp_relative_pointer_manager_v1, zwp_relative_pointer_v1};
use wayland_protocols::wp::tablet::zv2::client::{
    zwp_tablet_manager_v2, zwp_tablet_pad_group_v2, zwp_tablet_pad_ring_v2, zwp_tablet_pad_strip_v2,
    zwp_tablet_pad_v2, zwp_tablet_seat_v2, zwp_tablet_tool_v2, zwp_tablet_v2,
};
use wayland_protocols::wp::text_input::zv3::client::{zwp_text_input_manager_v3, zwp_text_input_v3};
use wayland_protocols::wp::viewporter::client::{wp_viewport, wp_viewporter};
use wayland_protocols::xdg::activation::v1::client::{xdg_activation_token_v1, xdg_activation_v1};
use wayland_protocols::xdg::decoration::zv1::client::{zxdg_decoration_manager_v1, zxdg_toplevel_decoration_v1};
use wayland_protocols::xdg::shell::client::{xdg_surface, xdg_toplevel, xdg_wm_base};
use wayland_protocols::xdg::toplevel_icon::v1::client::{xdg_toplevel_icon_manager_v1, xdg_toplevel_icon_v1};
use wayland_protocols::xdg::xdg_output::zv1::client::{zxdg_output_manager_v1, zxdg_output_v1};
use wayland_protocols_misc::server_decoration::client::{org_kde_kwin_server_decoration, org_kde_kwin_server_decoration_manager};

/// What the client heard back.
#[derive(Default)]
pub struct App {
    configured: bool,
    capabilities: Option<wl_seat::Capability>,
    output_modes: u32,
    frame_done: bool,
    token: Option<String>,
}

/// An ordinary Wayland client of the compositor.
pub struct Probe {
    conn: Connection,
    queue: EventQueue<App>,
    app: App,
    globals: GlobalList,
    qh: QueueHandle<App>,
}

/// A mapped xdg toplevel with a buffer.
pub struct Toplevel {
    pub surface: wl_surface::WlSurface,
    #[allow(dead_code)]
    xdg: xdg_surface::XdgSurface,
    #[allow(dead_code)]
    toplevel: xdg_toplevel::XdgToplevel,
    #[allow(dead_code)]
    buffer: wl_buffer::WlBuffer,
}

impl Toplevel {
    pub fn commit(&self) {
        self.surface.commit();
    }
}

macro_rules! ignore_events {
    ($($t:ty),+ $(,)?) => {$(
        impl Dispatch<$t, ()> for App {
            fn event(_: &mut Self, _: &$t, _: <$t as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
    )+};
}

ignore_events!(
    wl_compositor::WlCompositor, wl_subcompositor::WlSubcompositor, wl_subsurface::WlSubsurface, wl_shm::WlShm,
    wl_shm_pool::WlShmPool, wl_buffer::WlBuffer, wl_surface::WlSurface, wl_data_device_manager::WlDataDeviceManager,
    wl_data_offer::WlDataOffer, wl_data_source::WlDataSource, wl_pointer::WlPointer, wl_keyboard::WlKeyboard,
    wl_touch::WlTouch, xdg_wm_base::XdgWmBase, xdg_toplevel::XdgToplevel,
    zxdg_decoration_manager_v1::ZxdgDecorationManagerV1, zxdg_toplevel_decoration_v1::ZxdgToplevelDecorationV1,
    org_kde_kwin_server_decoration_manager::OrgKdeKwinServerDecorationManager,
    org_kde_kwin_server_decoration::OrgKdeKwinServerDecoration, zxdg_output_manager_v1::ZxdgOutputManagerV1,
    zxdg_output_v1::ZxdgOutputV1, wp_viewporter::WpViewporter, wp_viewport::WpViewport,
    wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1, wp_fractional_scale_v1::WpFractionalScaleV1,
    wp_cursor_shape_manager_v1::WpCursorShapeManagerV1, wp_cursor_shape_device_v1::WpCursorShapeDeviceV1,
    wp_presentation::WpPresentation, wp_presentation_feedback::WpPresentationFeedback,
    zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1, zwp_linux_buffer_params_v1::ZwpLinuxBufferParamsV1,
    zwp_linux_dmabuf_feedback_v1::ZwpLinuxDmabufFeedbackV1,
    zwp_relative_pointer_manager_v1::ZwpRelativePointerManagerV1, zwp_relative_pointer_v1::ZwpRelativePointerV1,
    zwp_pointer_constraints_v1::ZwpPointerConstraintsV1, zwp_locked_pointer_v1::ZwpLockedPointerV1,
    zwp_confined_pointer_v1::ZwpConfinedPointerV1, zwp_pointer_gestures_v1::ZwpPointerGesturesV1,
    zwp_pointer_gesture_pinch_v1::ZwpPointerGesturePinchV1, zwp_pointer_gesture_swipe_v1::ZwpPointerGestureSwipeV1,
    zwp_pointer_gesture_hold_v1::ZwpPointerGestureHoldV1,
    zwp_primary_selection_device_manager_v1::ZwpPrimarySelectionDeviceManagerV1,
    zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1,
    zwp_primary_selection_source_v1::ZwpPrimarySelectionSourceV1, zwp_tablet_manager_v2::ZwpTabletManagerV2,
    zwp_tablet_v2::ZwpTabletV2, zwp_tablet_tool_v2::ZwpTabletToolV2,
    zwp_tablet_pad_ring_v2::ZwpTabletPadRingV2, zwp_tablet_pad_strip_v2::ZwpTabletPadStripV2,
    zwp_text_input_manager_v3::ZwpTextInputManagerV3, zwp_text_input_v3::ZwpTextInputV3,
    xdg_toplevel_icon_manager_v1::XdgToplevelIconManagerV1, xdg_toplevel_icon_v1::XdgToplevelIconV1,
    zwp_idle_inhibit_manager_v1::ZwpIdleInhibitManagerV1, zwp_idle_inhibitor_v1::ZwpIdleInhibitorV1,
    wp_content_type_manager_v1::WpContentTypeManagerV1, wp_content_type_v1::WpContentTypeV1,
    xdg_activation_v1::XdgActivationV1,
    zwp_keyboard_shortcuts_inhibit_manager_v1::ZwpKeyboardShortcutsInhibitManagerV1,
    zwp_keyboard_shortcuts_inhibitor_v1::ZwpKeyboardShortcutsInhibitorV1,
);

impl Dispatch<wl_data_device::WlDataDevice, ()> for App {
    fn event(_: &mut Self, _: &wl_data_device::WlDataDevice, _: wl_data_device::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    wayland_client::event_created_child!(App, wl_data_device::WlDataDevice, [
        wl_data_device::EVT_DATA_OFFER_OPCODE => (wl_data_offer::WlDataOffer, ()),
    ]);
}

impl Dispatch<zwp_primary_selection_device_v1::ZwpPrimarySelectionDeviceV1, ()> for App {
    fn event(_: &mut Self, _: &zwp_primary_selection_device_v1::ZwpPrimarySelectionDeviceV1, _: zwp_primary_selection_device_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    wayland_client::event_created_child!(App, zwp_primary_selection_device_v1::ZwpPrimarySelectionDeviceV1, [
        zwp_primary_selection_device_v1::EVT_DATA_OFFER_OPCODE => (zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1, ()),
    ]);
}

impl Dispatch<zwp_tablet_seat_v2::ZwpTabletSeatV2, ()> for App {
    fn event(_: &mut Self, _: &zwp_tablet_seat_v2::ZwpTabletSeatV2, _: zwp_tablet_seat_v2::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    wayland_client::event_created_child!(App, zwp_tablet_seat_v2::ZwpTabletSeatV2, [
        zwp_tablet_seat_v2::EVT_TABLET_ADDED_OPCODE => (zwp_tablet_v2::ZwpTabletV2, ()),
        zwp_tablet_seat_v2::EVT_TOOL_ADDED_OPCODE => (zwp_tablet_tool_v2::ZwpTabletToolV2, ()),
        zwp_tablet_seat_v2::EVT_PAD_ADDED_OPCODE => (zwp_tablet_pad_v2::ZwpTabletPadV2, ()),
    ]);
}

impl Dispatch<zwp_tablet_pad_v2::ZwpTabletPadV2, ()> for App {
    fn event(_: &mut Self, _: &zwp_tablet_pad_v2::ZwpTabletPadV2, _: zwp_tablet_pad_v2::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    wayland_client::event_created_child!(App, zwp_tablet_pad_v2::ZwpTabletPadV2, [
        zwp_tablet_pad_v2::EVT_GROUP_OPCODE => (zwp_tablet_pad_group_v2::ZwpTabletPadGroupV2, ()),
    ]);
}

impl Dispatch<zwp_tablet_pad_group_v2::ZwpTabletPadGroupV2, ()> for App {
    fn event(_: &mut Self, _: &zwp_tablet_pad_group_v2::ZwpTabletPadGroupV2, _: zwp_tablet_pad_group_v2::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    wayland_client::event_created_child!(App, zwp_tablet_pad_group_v2::ZwpTabletPadGroupV2, [
        zwp_tablet_pad_group_v2::EVT_RING_OPCODE => (zwp_tablet_pad_ring_v2::ZwpTabletPadRingV2, ()),
        zwp_tablet_pad_group_v2::EVT_STRIP_OPCODE => (zwp_tablet_pad_strip_v2::ZwpTabletPadStripV2, ()),
    ]);
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for App {
    fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_seat::WlSeat, ()> for App {
    fn event(app: &mut Self, _: &wl_seat::WlSeat, event: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wl_seat::Event::Capabilities { capabilities: WEnum::Value(c) } = event {
            app.capabilities = Some(c);
        }
    }
}

impl Dispatch<wl_output::WlOutput, ()> for App {
    fn event(app: &mut Self, _: &wl_output::WlOutput, event: wl_output::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if matches!(event, wl_output::Event::Mode { .. } | wl_output::Event::Geometry { .. }) {
            app.output_modes += 1;
        }
    }
}

impl Dispatch<xdg_surface::XdgSurface, ()> for App {
    fn event(app: &mut Self, surface: &xdg_surface::XdgSurface, event: xdg_surface::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let xdg_surface::Event::Configure { serial } = event {
            surface.ack_configure(serial);
            app.configured = true;
        }
    }
}

impl Dispatch<wl_callback::WlCallback, ()> for App {
    fn event(app: &mut Self, _: &wl_callback::WlCallback, _: wl_callback::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        app.frame_done = true;
    }
}

impl Dispatch<xdg_activation_token_v1::XdgActivationTokenV1, ()> for App {
    fn event(app: &mut Self, _: &xdg_activation_token_v1::XdgActivationTokenV1, event: xdg_activation_token_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let xdg_activation_token_v1::Event::Done { token } = event {
            app.token = Some(token);
        }
    }
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

impl Probe {
    pub fn connect(server: &Server) -> Probe {
        let stream = UnixStream::connect(server.wayland_socket()).expect("connect to the Wayland socket");
        let conn = Connection::from_socket(stream).expect("a Wayland connection");
        let (globals, queue) = registry_queue_init::<App>(&conn).expect("the registry");
        let qh = queue.handle();
        Probe { conn, queue, app: App::default(), globals, qh }
    }

    pub fn globals(&self) -> Vec<(String, u32)> {
        self.globals.contents().with_list(|l| l.iter().map(|g| (g.interface.clone(), g.version)).collect())
    }

    pub fn roundtrip(&mut self) -> Result<(), String> {
        self.queue.roundtrip(&mut self.app).map(|_| ()).map_err(err)
    }

    pub fn dispatch_pending(&mut self) -> Result<(), String> {
        self.conn.flush().map_err(err)?;
        if let Some(guard) = self.queue.prepare_read() {
            let _ = guard.read();
        }
        self.queue.dispatch_pending(&mut self.app).map(|_| ()).map_err(err)
    }

    pub fn frame_done(&self) -> bool {
        self.app.frame_done
    }

    /// Binds a global at the version the compositor advertises (up to this client's own).
    fn bind<I>(&self) -> Result<I, String>
    where
        I: Proxy + 'static,
        App: Dispatch<I, ()>,
    {
        let max = I::interface().version;
        let bound: I = self.globals.bind(&self.qh, 1..=max, ()).map_err(err)?;
        let advertised = self
            .globals
            .contents()
            .with_list(|l| l.iter().find(|g| g.interface == I::interface().name).map(|g| g.version));
        if let Some(advertised) = advertised {
            if bound.version() != advertised.min(max) {
                return Err(format!("bound v{}, advertised v{advertised}", bound.version()));
            }
        }
        Ok(bound)
    }

    pub fn surface(&self) -> Result<wl_surface::WlSurface, String> {
        Ok(self.bind::<wl_compositor::WlCompositor>()?.create_surface(&self.qh, ()))
    }

    pub fn subsurface(&self) -> Result<(), String> {
        let parent = self.surface()?;
        let child = self.surface()?;
        self.bind::<wl_subcompositor::WlSubcompositor>()?.get_subsurface(&child, &parent, &self.qh, ());
        Ok(())
    }

    pub fn shm_buffer(&self) -> Result<wl_buffer::WlBuffer, String> {
        let (w, h) = (64, 64);
        let size = (w * h * 4) as i64;
        // SAFETY: memfd_create with a static name; the descriptor is owned right away.
        let fd = unsafe { libc::memfd_create(c"caboose-test".as_ptr(), 0) };
        if fd < 0 {
            return Err("memfd_create".into());
        }
        // SAFETY: fd is a fresh descriptor nothing else owns.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: ftruncate on our own memfd.
        if unsafe { libc::ftruncate(std::os::fd::AsRawFd::as_raw_fd(&fd), size) } != 0 {
            return Err("ftruncate".into());
        }
        let shm = self.bind::<wl_shm::WlShm>()?;
        let pool = shm.create_pool(fd.as_fd(), size as i32, &self.qh, ());
        Ok(pool.create_buffer(0, w, h, w * 4, wl_shm::Format::Argb8888, &self.qh, ()))
    }

    /// An xdg toplevel with a buffer attached and committed: a mapped window.
    pub fn toplevel(&mut self) -> Result<Toplevel, String> {
        let surface = self.surface()?;
        let xdg = self.bind::<xdg_wm_base::XdgWmBase>()?.get_xdg_surface(&surface, &self.qh, ());
        let toplevel = xdg.get_toplevel(&self.qh, ());
        toplevel.set_title("test".into());
        toplevel.set_app_id("caboose.test".into());
        surface.commit();
        self.app.configured = false;
        for _ in 0..50 {
            self.roundtrip()?;
            if self.app.configured {
                break;
            }
        }
        if !self.app.configured {
            return Err("the toplevel was never configured".into());
        }
        let buffer = self.shm_buffer()?;
        surface.attach(Some(&buffer), 0, 0);
        surface.damage(0, 0, 64, 64);
        surface.commit();
        self.roundtrip()?;
        Ok(Toplevel { surface, xdg, toplevel, buffer })
    }

    pub fn request_frame(&self, window: &Toplevel) {
        self.app_frame_reset();
        window.surface.frame(&self.qh, ());
        window.surface.commit();
    }

    fn app_frame_reset(&self) {}

    pub fn output(&mut self) -> Result<(), String> {
        let _output = self.bind::<wl_output::WlOutput>()?;
        self.roundtrip()?;
        if self.app.output_modes == 0 {
            return Err("the output described nothing".into());
        }
        Ok(())
    }

    pub fn seat_capabilities(&mut self) -> Result<(), String> {
        let _seat = self.bind::<wl_seat::WlSeat>()?;
        self.roundtrip()?;
        self.app.capabilities.map(|_| ()).ok_or_else(|| "the seat sent no capabilities".to_owned())
    }

    pub fn has_capability(&mut self, name: &str) -> bool {
        let Ok(_seat) = self.bind::<wl_seat::WlSeat>() else { return false };
        self.roundtrip().ok();
        self.app.capabilities.is_some_and(|c| match name {
            "touch" => c.contains(wl_seat::Capability::Touch),
            "pointer" => c.contains(wl_seat::Capability::Pointer),
            "keyboard" => c.contains(wl_seat::Capability::Keyboard),
            _ => false,
        })
    }

    fn seat(&mut self) -> Result<wl_seat::WlSeat, String> {
        let seat = self.bind::<wl_seat::WlSeat>()?;
        self.roundtrip()?;
        Ok(seat)
    }

    pub fn data_device(&mut self) -> Result<(), String> {
        let seat = self.seat()?;
        let manager = self.bind::<wl_data_device_manager::WlDataDeviceManager>()?;
        manager.get_data_device(&seat, &self.qh, ());
        manager.create_data_source(&self.qh, ());
        Ok(())
    }

    pub fn decoration(&mut self) -> Result<(), String> {
        let window = self.toplevel()?;
        self.bind::<zxdg_decoration_manager_v1::ZxdgDecorationManagerV1>()?.get_toplevel_decoration(&window.toplevel, &self.qh, ());
        Ok(())
    }

    pub fn kde_decoration(&mut self) -> Result<(), String> {
        let surface = self.surface()?;
        self.bind::<org_kde_kwin_server_decoration_manager::OrgKdeKwinServerDecorationManager>()?.create(&surface, &self.qh, ());
        Ok(())
    }

    pub fn xdg_output(&mut self) -> Result<(), String> {
        let output = self.bind::<wl_output::WlOutput>()?;
        self.bind::<zxdg_output_manager_v1::ZxdgOutputManagerV1>()?.get_xdg_output(&output, &self.qh, ());
        Ok(())
    }

    pub fn viewport(&mut self) -> Result<(), String> {
        let surface = self.surface()?;
        self.bind::<wp_viewporter::WpViewporter>()?.get_viewport(&surface, &self.qh, ());
        Ok(())
    }

    pub fn fractional_scale(&mut self) -> Result<(), String> {
        let surface = self.surface()?;
        self.bind::<wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1>()?.get_fractional_scale(&surface, &self.qh, ());
        Ok(())
    }

    fn pointer(&mut self) -> Result<wl_pointer::WlPointer, String> {
        let seat = self.seat()?;
        Ok(seat.get_pointer(&self.qh, ()))
    }

    pub fn cursor_shape(&mut self) -> Result<(), String> {
        let pointer = self.pointer()?;
        self.bind::<wp_cursor_shape_manager_v1::WpCursorShapeManagerV1>()?.get_pointer(&pointer, &self.qh, ());
        Ok(())
    }

    pub fn presentation(&mut self) -> Result<(), String> {
        let surface = self.surface()?;
        self.bind::<wp_presentation::WpPresentation>()?.feedback(&surface, &self.qh, ());
        Ok(())
    }

    pub fn dmabuf(&mut self) -> Result<(), String> {
        let dmabuf = self.bind::<zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1>()?;
        dmabuf.create_params(&self.qh, ());
        if dmabuf.version() >= 4 {
            dmabuf.get_default_feedback(&self.qh, ());
        }
        Ok(())
    }

    pub fn relative_pointer(&mut self) -> Result<(), String> {
        let pointer = self.pointer()?;
        self.bind::<zwp_relative_pointer_manager_v1::ZwpRelativePointerManagerV1>()?.get_relative_pointer(&pointer, &self.qh, ());
        Ok(())
    }

    pub fn pointer_constraints(&mut self) -> Result<(), String> {
        let pointer = self.pointer()?;
        let surface = self.surface()?;
        self.bind::<zwp_pointer_constraints_v1::ZwpPointerConstraintsV1>()?.lock_pointer(
            &surface,
            &pointer,
            None,
            zwp_pointer_constraints_v1::Lifetime::Oneshot,
            &self.qh,
            (),
        );
        Ok(())
    }

    pub fn pointer_gestures(&mut self) -> Result<(), String> {
        let pointer = self.pointer()?;
        let gestures = self.bind::<zwp_pointer_gestures_v1::ZwpPointerGesturesV1>()?;
        gestures.get_pinch_gesture(&pointer, &self.qh, ());
        gestures.get_swipe_gesture(&pointer, &self.qh, ());
        if gestures.version() >= 3 {
            gestures.get_hold_gesture(&pointer, &self.qh, ());
        }
        Ok(())
    }

    pub fn primary_selection(&mut self) -> Result<(), String> {
        let seat = self.seat()?;
        let manager = self.bind::<zwp_primary_selection_device_manager_v1::ZwpPrimarySelectionDeviceManagerV1>()?;
        manager.get_device(&seat, &self.qh, ());
        manager.create_source(&self.qh, ());
        Ok(())
    }

    pub fn tablet(&mut self) -> Result<(), String> {
        let seat = self.seat()?;
        self.bind::<zwp_tablet_manager_v2::ZwpTabletManagerV2>()?.get_tablet_seat(&seat, &self.qh, ());
        Ok(())
    }

    pub fn text_input(&mut self) -> Result<(), String> {
        let seat = self.seat()?;
        self.bind::<zwp_text_input_manager_v3::ZwpTextInputManagerV3>()?.get_text_input(&seat, &self.qh, ());
        Ok(())
    }

    pub fn toplevel_icon(&mut self) -> Result<(), String> {
        self.bind::<xdg_toplevel_icon_manager_v1::XdgToplevelIconManagerV1>()?.create_icon(&self.qh, ());
        Ok(())
    }

    pub fn idle_inhibit(&mut self) -> Result<zwp_idle_inhibit_manager_v1::ZwpIdleInhibitManagerV1, String> {
        self.bind()
    }

    pub fn idle_inhibit_on(&mut self, window: &Toplevel) -> Result<zwp_idle_inhibitor_v1::ZwpIdleInhibitorV1, String> {
        Ok(self.idle_inhibit()?.create_inhibitor(&window.surface, &self.qh, ()))
    }

    pub fn content_type(&mut self, kind: wp_content_type_v1::Type) -> Result<wp_content_type_v1::WpContentTypeV1, String> {
        let surface = self.surface()?;
        let content = self.bind::<wp_content_type_manager_v1::WpContentTypeManagerV1>()?.get_surface_content_type(&surface, &self.qh, ());
        content.set_content_type(kind);
        Ok(content)
    }

    pub fn content_type_on(&mut self, window: &Toplevel, kind: wp_content_type_v1::Type) -> Result<wp_content_type_v1::WpContentTypeV1, String> {
        let content = self.bind::<wp_content_type_manager_v1::WpContentTypeManagerV1>()?.get_surface_content_type(&window.surface, &self.qh, ());
        content.set_content_type(kind);
        window.surface.commit();
        Ok(content)
    }

    pub fn activation_token(&mut self) -> Result<String, String> {
        let token = self.bind::<xdg_activation_v1::XdgActivationV1>()?.get_activation_token(&self.qh, ());
        self.app.token = None;
        token.commit();
        self.roundtrip()?;
        self.app.token.take().ok_or_else(|| "no token came back".into())
    }

    /// A token for `window`, made as that window's application.
    pub fn activation_token_for(&mut self, window: &Toplevel) -> Result<String, String> {
        let token = self.bind::<xdg_activation_v1::XdgActivationV1>()?.get_activation_token(&self.qh, ());
        self.app.token = None;
        token.set_surface(&window.surface);
        token.commit();
        self.roundtrip()?;
        self.app.token.take().ok_or_else(|| "no token came back".into())
    }

    pub fn activate(&mut self, token: &str, window: &Toplevel) -> Result<(), String> {
        self.bind::<xdg_activation_v1::XdgActivationV1>()?.activate(token.to_owned(), &window.surface);
        Ok(())
    }

    pub fn shortcuts_inhibitor(&mut self) -> Result<zwp_keyboard_shortcuts_inhibitor_v1::ZwpKeyboardShortcutsInhibitorV1, String> {
        let window = self.toplevel()?;
        self.shortcuts_inhibitor_on(&window)
    }

    pub fn shortcuts_inhibitor_on(&mut self, window: &Toplevel) -> Result<zwp_keyboard_shortcuts_inhibitor_v1::ZwpKeyboardShortcutsInhibitorV1, String> {
        let seat = self.seat()?;
        Ok(self
            .bind::<zwp_keyboard_shortcuts_inhibit_manager_v1::ZwpKeyboardShortcutsInhibitManagerV1>()?
            .inhibit_shortcuts(&window.surface, &seat, &self.qh, ()))
    }
}
