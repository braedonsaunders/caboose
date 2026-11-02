//! caboose-display-testbench: an ordinary Wayland client (or, with `--x11`,
//! an ordinary X11 client) that tests the compositor from outside, the way
//! LordOS's testbench does. It shows a marker that steps one position per
//! frame, reads wp_presentation feedback, logs every input event with a
//! timestamp, lists the advertised globals, and runs a protocol checklist.
//!
//!   caboose-display-testbench                 interactive, until closed
//!   caboose-display-testbench --auto [secs]   run, print a JSON report, exit
//!   caboose-display-testbench --x11 --auto    the same over X11/Xwayland
//!
//! Exit status is 0 unless a checklist item failed (or it could not run).

mod x11;

use caboose_display_testbench::{Check, CheckState, InputEvent, Marker, Presented, Report};
use std::time::{Duration, Instant};

pub fn now_us(start: Instant) -> u64 {
    start.elapsed().as_micros() as u64
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let x11_mode = args.iter().any(|a| a == "--x11");
    let auto = args.iter().position(|a| a == "--auto").map(|i| {
        args.get(i + 1).and_then(|s| s.parse::<f64>().ok()).unwrap_or(5.0)
    });
    let code = if x11_mode {
        x11::run(auto)
    } else {
        wayland::run(auto)
    };
    std::process::exit(code);
}

mod wayland {
    use super::*;
    use std::os::unix::io::AsFd;
    use wayland_client::protocol::{
        wl_buffer, wl_callback, wl_compositor, wl_keyboard, wl_output, wl_pointer, wl_registry, wl_seat, wl_shm,
        wl_shm_pool, wl_surface,
    };
    use wayland_client::{Connection, Dispatch, QueueHandle, WEnum};
    use wayland_protocols::wp::presentation_time::client::{wp_presentation, wp_presentation_feedback};
    use wayland_protocols::xdg::shell::client::{xdg_surface, xdg_toplevel, xdg_wm_base};

    const W: i32 = 640;
    const H: i32 = 360;

    struct Buf {
        buffer: Option<wl_buffer::WlBuffer>,
        ptr: *mut u32,
        size: usize,
        busy: bool,
    }

    pub struct State {
        start: Instant,
        report: Report,
        marker: Marker,
        configured: bool,
        closed: bool,
        frame_pending: bool,
        shm_argb: bool,
        shm_xrgb: bool,
        output_mode: Option<(i32, i32, i32)>,
        has_keyboard: bool,
        has_pointer: bool,
        feedback_clock: Option<u32>,
        bufs: Vec<Buf>,
        surface: Option<wl_surface::WlSurface>,
        presentation: Option<wp_presentation::WpPresentation>,
    }

    fn draw(state: &mut State, qh: &QueueHandle<State>) {
        let Some(surface) = state.surface.clone() else { return };
        let Some(buf) = state.bufs.iter_mut().find(|b| !b.busy) else { return };
        let frame = state.marker.frame;
        // Background, the stepping marker, and the frame's binary blocks.
        let pixels = unsafe { std::slice::from_raw_parts_mut(buf.ptr, (W * H) as usize) };
        for p in pixels.iter_mut() {
            *p = 0xff12_121a;
        }
        let mx = state.marker.x(W);
        for y in 48..(H - 48) {
            for x in mx..(mx + caboose_display_testbench::MARKER_W) {
                if x < W {
                    pixels[(y * W + x) as usize] = 0xffff_ffff;
                }
            }
        }
        for (i, on) in state.marker.frame_bits().iter().enumerate() {
            let x0 = 16 + i as i32 * 24;
            for y in 16..40 {
                for x in x0..(x0 + 16) {
                    pixels[(y * W + x) as usize] = if *on { 0xff78_e696 } else { 0xff2c_2c38 };
                }
            }
        }
        let buffer = buf.buffer.clone().unwrap();
        buf.busy = true;
        surface.attach(Some(&buffer), 0, 0);
        surface.damage(0, 0, W, H);
        if let Some(p) = &state.presentation {
            p.feedback(&surface, qh, frame);
        }
        surface.frame(qh, ());
        surface.commit();
        state.frame_pending = true;
        state.report.frames = frame + 1;
        state.marker.advance();
    }

    pub fn run(auto: Option<f64>) -> i32 {
        let start = Instant::now();
        let conn = match Connection::connect_to_env() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("testbench: cannot connect to the compositor: {e}");
                return 2;
            }
        };
        let mut queue = conn.new_event_queue::<State>();
        let qh = queue.handle();
        let _registry = conn.display().get_registry(&qh, ());
        let mut state = State {
            start,
            report: Report { mode: "wayland".into(), width: W, height: H, ..Default::default() },
            marker: Marker::default(),
            configured: false,
            closed: false,
            frame_pending: false,
            shm_argb: false,
            shm_xrgb: false,
            output_mode: None,
            has_keyboard: false,
            has_pointer: false,
            feedback_clock: None,
            bufs: Vec::new(),
            surface: None,
            presentation: None,
        };
        // Registry roundtrip: collect the globals.
        if queue.roundtrip(&mut state).is_err() {
            eprintln!("testbench: the compositor ended the connection during setup");
            return 2;
        }
        let deadline = auto.map(|s| start + Duration::from_secs_f64(s));
        let mut last_draw = Instant::now();
        while !state.closed {
            let timeout = Duration::from_millis(50);
            if queue.dispatch_pending(&mut state).is_err() {
                break;
            }
            if state.configured && !state.frame_pending && !state.bufs.is_empty() {
                draw(&mut state, &qh);
            }
            let _ = conn.flush();
            if let Some(read) = conn.prepare_read() {
                let _ = read.read();
            }
            if let Some(d) = deadline {
                if Instant::now() >= d {
                    break;
                }
            } else if last_draw.elapsed() > Duration::from_secs(3600) {
                break;
            }
            std::thread::sleep(Duration::from_millis(2));
            last_draw = Instant::now();
        }
        finish(state, auto.is_some())
    }

    fn finish(mut state: State, auto: bool) -> i32 {
        let c = &mut state.report.checks;
        let has = |name: &str| state.report.globals.iter().any(|(n, _)| n == name);
        c.push(Check::new("globals_core", if has("wl_compositor") && has("wl_shm") && has("xdg_wm_base") { CheckState::Pass } else { CheckState::Fail },
            format!("{} globals advertised", state.report.globals.len())));
        c.push(Check::new("shm_argb8888", if state.shm_argb { CheckState::Pass } else { CheckState::Fail }, "ARGB8888 advertised by wl_shm"));
        c.push(Check::new("shm_xrgb8888", if state.shm_xrgb { CheckState::Pass } else { CheckState::Fail }, "XRGB8888 advertised by wl_shm"));
        c.push(Check::new("xdg_configure", if state.configured { CheckState::Pass } else { CheckState::Fail }, "xdg_surface configure received and acked"));
        c.push(Check::new("frame_callback", if state.report.frames > 1 { CheckState::Pass } else { CheckState::Fail },
            format!("{} frames committed", state.report.frames)));
        c.push(Check::new("presentation_feedback", if !state.report.presented.is_empty() { CheckState::Pass } else if state.presentation.is_some() { CheckState::Fail } else { CheckState::Info },
            if state.presentation.is_some() { format!("{} presented, clock {:?}", state.report.presented.len(), state.feedback_clock) } else { "wp_presentation not advertised".into() }));
        c.push(Check::new("output_mode", if state.output_mode.is_some() { CheckState::Pass } else { CheckState::Fail },
            format!("current mode {:?}", state.output_mode)));
        c.push(Check::new("seat_input", if state.has_keyboard || state.has_pointer { CheckState::Pass } else { CheckState::Info },
            format!("keyboard {} pointer {}", state.has_keyboard, state.has_pointer)));
        c.push(Check::new("input_events", CheckState::Info, format!("{} input events logged", state.report.inputs.len())));
        let failed = state.report.failed();
        if auto {
            print!("{}", state.report.to_json());
        } else {
            eprintln!("testbench: {} frames, {} checks failed", state.report.frames, failed);
        }
        if failed { 1 } else { 0 }
    }

    fn make_buffer(state: &State, shm: &wl_shm::WlShm, qh: &QueueHandle<State>, idx: usize) -> Buf {
        let size = (W * H * 4) as usize;
        let fd = unsafe { libc::memfd_create(b"caboose-testbench\0".as_ptr() as *const libc::c_char, libc::MFD_CLOEXEC) };
        assert!(fd >= 0 && unsafe { libc::ftruncate(fd, size as libc::off_t) } == 0, "memfd for the testbench buffer");
        let ptr = unsafe { libc::mmap(std::ptr::null_mut(), size, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0) };
        assert!(ptr != libc::MAP_FAILED, "mmap the testbench buffer");
        let pool = shm.create_pool(unsafe { std::os::unix::io::BorrowedFd::borrow_raw(fd) }, size as i32, qh, idx);
        let buffer = pool.create_buffer(0, W, H, W * 4, wl_shm::Format::Xrgb8888, qh, idx);
        pool.destroy();
        unsafe { libc::close(fd) };
        Buf { buffer: Some(buffer), ptr: ptr as *mut u32, size, busy: false }
    }

    impl Dispatch<wl_registry::WlRegistry, ()> for State {
        fn event(s: &mut State, r: &wl_registry::WlRegistry, e: wl_registry::Event, _: &(), _: &Connection, qh: &QueueHandle<State>) {
            if let wl_registry::Event::Global { name, interface, version } = e {
                s.report.globals.push((interface.clone(), version));
                match interface.as_str() {
                    "wl_compositor" => {
                        let comp: wl_compositor::WlCompositor = r.bind(name, version.min(6), qh, ());
                        let surface = comp.create_surface(qh, ());
                        s.surface = Some(surface);
                    }
                    "wl_shm" => {
                        let shm: wl_shm::WlShm = r.bind(name, version.min(1), qh, ());
                        s.bufs = (0..2).map(|i| make_buffer(s, &shm, qh, i)).collect();
                        // Bind a second handle purely to receive the format events.
                        let _: wl_shm::WlShm = r.bind(name, version.min(1), qh, ());
                    }
                    "xdg_wm_base" => {
                        let wm: xdg_wm_base::XdgWmBase = r.bind(name, version.min(6), qh, ());
                        if let Some(surface) = s.surface.clone() {
                            let xs = wm.get_xdg_surface(&surface, qh, ());
                            let top = xs.get_toplevel(qh, ());
                            top.set_title("Caboose testbench".into());
                            surface.commit();
                            std::mem::forget(xs);
                            std::mem::forget(top);
                        }
                        std::mem::forget(wm);
                    }
                    "wl_seat" => {
                        let seat: wl_seat::WlSeat = r.bind(name, version.min(7), qh, ());
                        std::mem::forget(seat);
                    }
                    "wl_output" => {
                        let out: wl_output::WlOutput = r.bind(name, version.min(4), qh, ());
                        std::mem::forget(out);
                    }
                    "wp_presentation" => {
                        let p: wp_presentation::WpPresentation = r.bind(name, version.min(2), qh, ());
                        s.presentation = Some(p);
                    }
                    _ => {}
                }
            }
        }
    }

    impl Dispatch<wl_shm::WlShm, ()> for State {
        fn event(s: &mut State, _: &wl_shm::WlShm, e: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if let wl_shm::Event::Format { format } = e {
                match format {
                    WEnum::Value(wl_shm::Format::Argb8888) => s.shm_argb = true,
                    WEnum::Value(wl_shm::Format::Xrgb8888) => s.shm_xrgb = true,
                    _ => {}
                }
            }
        }
    }

    impl Dispatch<wl_compositor::WlCompositor, ()> for State {
        fn event(_: &mut State, _: &wl_compositor::WlCompositor, _: wl_compositor::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {}
    }
    impl Dispatch<wl_surface::WlSurface, ()> for State {
        fn event(_: &mut State, _: &wl_surface::WlSurface, _: wl_surface::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {}
    }
    impl Dispatch<wl_buffer::WlBuffer, usize> for State {
        fn event(s: &mut State, b: &wl_buffer::WlBuffer, e: wl_buffer::Event, idx: &usize, _: &Connection, _: &QueueHandle<State>) {
            let _ = b;
            if matches!(e, wl_buffer::Event::Release) {
                if let Some(buf) = s.bufs.get_mut(*idx) {
                    buf.busy = false;
                }
            }
        }
    }
    impl Dispatch<wl_shm_pool::WlShmPool, usize> for State {
        fn event(_: &mut State, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &usize, _: &Connection, _: &QueueHandle<State>) {}
    }
    impl Dispatch<wl_callback::WlCallback, ()> for State {
        fn event(s: &mut State, cb: &wl_callback::WlCallback, e: wl_callback::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if matches!(e, wl_callback::Event::Done { .. }) {
                s.frame_pending = false;
            }
        }
    }
    impl Dispatch<xdg_wm_base::XdgWmBase, ()> for State {
        fn event(_: &mut State, wm: &xdg_wm_base::XdgWmBase, e: xdg_wm_base::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if let xdg_wm_base::Event::Ping { serial } = e {
                wm.pong(serial);
            }
        }
    }
    impl Dispatch<xdg_surface::XdgSurface, ()> for State {
        fn event(s: &mut State, xs: &xdg_surface::XdgSurface, e: xdg_surface::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if let xdg_surface::Event::Configure { serial } = e {
                xs.ack_configure(serial);
                s.configured = true;
            }
        }
    }
    impl Dispatch<xdg_toplevel::XdgToplevel, ()> for State {
        fn event(s: &mut State, _: &xdg_toplevel::XdgToplevel, e: xdg_toplevel::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if matches!(e, xdg_toplevel::Event::Close) {
                s.closed = true;
            }
        }
    }
    impl Dispatch<wl_seat::WlSeat, ()> for State {
        fn event(s: &mut State, seat: &wl_seat::WlSeat, e: wl_seat::Event, _: &(), _: &Connection, qh: &QueueHandle<State>) {
            if let wl_seat::Event::Capabilities { capabilities } = e {
                if let WEnum::Value(c) = capabilities {
                    if c.contains(wl_seat::Capability::Keyboard) {
                        s.has_keyboard = true;
                        std::mem::forget(seat.get_keyboard(qh, ()));
                    }
                    if c.contains(wl_seat::Capability::Pointer) {
                        s.has_pointer = true;
                        std::mem::forget(seat.get_pointer(qh, ()));
                    }
                }
            }
        }
    }
    impl Dispatch<wl_keyboard::WlKeyboard, ()> for State {
        fn event(s: &mut State, _: &wl_keyboard::WlKeyboard, e: wl_keyboard::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            let kind = match e {
                wl_keyboard::Event::Key { .. } => "key",
                wl_keyboard::Event::Enter { .. } => "keyboard_enter",
                wl_keyboard::Event::Leave { .. } => "keyboard_leave",
                wl_keyboard::Event::Modifiers { .. } => "modifiers",
                wl_keyboard::Event::Keymap { .. } => "keymap",
                wl_keyboard::Event::RepeatInfo { .. } => "repeat_info",
                _ => "keyboard",
            };
            s.report.inputs.push(InputEvent { at_us: now_us(s.start), kind: kind.into(), detail: format!("{e:?}").chars().take(120).collect() });
        }
    }
    impl Dispatch<wl_pointer::WlPointer, ()> for State {
        fn event(s: &mut State, _: &wl_pointer::WlPointer, e: wl_pointer::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            let kind = match e {
                wl_pointer::Event::Motion { .. } => "motion",
                wl_pointer::Event::Button { .. } => "button",
                wl_pointer::Event::Axis { .. } => "axis",
                wl_pointer::Event::Enter { .. } => "pointer_enter",
                wl_pointer::Event::Leave { .. } => "pointer_leave",
                wl_pointer::Event::Frame => "pointer_frame",
                _ => "pointer",
            };
            s.report.inputs.push(InputEvent { at_us: now_us(s.start), kind: kind.into(), detail: format!("{e:?}").chars().take(120).collect() });
        }
    }
    impl Dispatch<wl_output::WlOutput, ()> for State {
        fn event(s: &mut State, _: &wl_output::WlOutput, e: wl_output::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if let wl_output::Event::Mode { flags, width, height, refresh } = e {
                if let WEnum::Value(f) = flags {
                    if f.contains(wl_output::Mode::Current) {
                        s.output_mode = Some((width, height, refresh));
                    }
                }
            }
        }
    }
    impl Dispatch<wp_presentation::WpPresentation, ()> for State {
        fn event(s: &mut State, _: &wp_presentation::WpPresentation, e: wp_presentation::Event, _: &(), _: &Connection, _: &QueueHandle<State>) {
            if let wp_presentation::Event::ClockId { clk_id } = e {
                s.feedback_clock = Some(clk_id);
            }
        }
    }
    impl Dispatch<wp_presentation_feedback::WpPresentationFeedback, u64> for State {
        fn event(s: &mut State, _: &wp_presentation_feedback::WpPresentationFeedback, e: wp_presentation_feedback::Event, frame: &u64, _: &Connection, _: &QueueHandle<State>) {
            match e {
                wp_presentation_feedback::Event::Presented { tv_sec_hi, tv_sec_lo, tv_nsec, refresh, seq_lo, seq_hi, .. } => {
                    let sec = ((tv_sec_hi as u64) << 32) | tv_sec_lo as u64;
                    s.report.presented.push(Presented {
                        frame: *frame,
                        presented_us: sec * 1_000_000 + (tv_nsec as u64) / 1000,
                        refresh_ns: refresh,
                        seq: ((seq_hi as u64) << 32) | seq_lo as u64,
                    });
                }
                wp_presentation_feedback::Event::Discarded => {}
                _ => {}
            }
        }
    }
    // Keep the fd import used on platforms where prepare_read differs.
    #[allow(dead_code)]
    fn _fd(conn: &Connection) -> std::os::unix::io::BorrowedFd<'_> {
        conn.as_fd()
    }
}
