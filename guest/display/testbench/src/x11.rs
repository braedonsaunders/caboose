//! The X11 mode: the same testbench as an ordinary X11 client, for seats
//! where the application under test reaches the compositor through Xwayland.
//! It maps a window, steps the marker on every expose, logs key and button
//! events with timestamps, and writes the same JSON report shape.

use caboose_display_testbench::{Check, CheckState, InputEvent, Marker, Report};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

const W: u16 = 640;
const H: u16 = 360;

pub fn run(auto: Option<f64>) -> i32 {
    let start = Instant::now();
    let (conn, screen_num) = match RustConnection::connect(None) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("testbench --x11: cannot connect to the X server: {e}");
            return 2;
        }
    };
    let screen = &conn.setup().roots[screen_num];
    let win = conn.generate_id().unwrap_or(0);
    let gc = conn.generate_id().unwrap_or(0);
    let mut report = Report { mode: "x11".into(), width: W as i32, height: H as i32, ..Default::default() };
    report.globals.push(("x11_core".into(), conn.setup().protocol_major_version as u32));
    let ok = (|| -> Option<()> {
        conn.create_window(
            0, // CopyFromParent
            win,
            screen.root,
            0,
            0,
            W,
            H,
            0,
            WindowClass::INPUT_OUTPUT,
            screen.root_visual,
            &CreateWindowAux::new()
                .background_pixel(screen.black_pixel)
                .event_mask(EventMask::EXPOSURE | EventMask::KEY_PRESS | EventMask::BUTTON_PRESS | EventMask::STRUCTURE_NOTIFY),
        )
        .ok()?;
        conn.create_gc(gc, win, &CreateGCAux::new().foreground(screen.white_pixel)).ok()?;
        conn.map_window(win).ok()?;
        conn.flush().ok()?;
        Some(())
    })();
    if ok.is_none() {
        eprintln!("testbench --x11: could not create and map its window");
        return 2;
    }
    let mut marker = Marker::default();
    let mut mapped = false;
    let mut exposed = 0u64;
    let deadline = auto.map(|s| start + Duration::from_secs_f64(s));
    loop {
        while let Ok(Some(event)) = conn.poll_for_event() {
            match event {
                Event::MapNotify(_) => mapped = true,
                Event::Expose(_) => {
                    exposed += 1;
                    let x = marker.x(W as i32) as i16;
                    let _ = conn.poly_fill_rectangle(win, gc, &[Rectangle { x, y: 48, width: 16, height: H - 96 }]);
                    let _ = conn.flush();
                    marker.advance();
                }
                Event::KeyPress(e) => report.inputs.push(InputEvent {
                    at_us: start.elapsed().as_micros() as u64,
                    kind: "key_press".into(),
                    detail: format!("detail={}", e.detail),
                }),
                Event::ButtonPress(e) => report.inputs.push(InputEvent {
                    at_us: start.elapsed().as_micros() as u64,
                    kind: "button_press".into(),
                    detail: format!("detail={} at {},{}", e.detail, e.event_x, e.event_y),
                }),
                _ => {}
            }
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            break;
        }
        if auto.is_none() && start.elapsed() > Duration::from_secs(3600) {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    report.frames = exposed;
    report.checks.push(Check::new("window_mapped", if mapped { CheckState::Pass } else { CheckState::Fail }, "MapNotify received"));
    report.checks.push(Check::new("expose_frames", if exposed > 1 { CheckState::Pass } else { CheckState::Fail }, format!("{exposed} exposes, marker stepped per expose")));
    report.checks.push(Check::new("input_events", CheckState::Info, format!("{} input events logged", report.inputs.len())));
    let failed = report.failed();
    if auto.is_some() {
        print!("{}", report.to_json());
    }
    if failed { 1 } else { 0 }
}
