//! Advertisement honesty: everything `caboose-display` tells a client it offers must work.
//!
//! The compositor runs for real (headless, no phone GPU) and two kinds of client look at
//! what it says:
//!
//! - an ordinary Wayland client lists the registry; every global must have a check below
//!   that binds it at the advertised version and exercises it, and a global without one
//!   fails the test, so a protocol cannot be advertised before it is serviced;
//! - a Caboose Display client reads the hello's `features`; every feature must be named in
//!   docs/display.md, must have its Wayland counterpart (or its own check), and must be
//!   absent when its precondition is.
//!
//! The hint protocols (idle inhibit, content type, keyboard grabs, activation) are
//! followed all the way to the window messages the phone acts on.
//!
//! Needs the runtime image (guest/display/Dockerfile): libEGL, Xwayland. Without them the
//! test says so and passes nothing it did not check.

mod support;

use caboose_display_protocol as proto;
use proto::{ContentType, Message};
use std::collections::BTreeMap;
use std::time::Duration;
use support::*;

/// What every advertised global is checked by. One entry per interface; the closure binds
/// the global and makes a request that needs the compositor's handler to answer.
type Check = fn(&mut Probe) -> Result<(), String>;

fn checks() -> BTreeMap<&'static str, Check> {
    let mut m: BTreeMap<&'static str, Check> = BTreeMap::new();
    m.insert("wl_compositor", |p| p.surface().map(|_| ()));
    m.insert("wl_subcompositor", |p| p.subsurface());
    m.insert("wl_shm", |p| p.shm_buffer().map(|_| ()));
    m.insert("wl_output", |p| p.output());
    m.insert("wl_seat", |p| p.seat_capabilities());
    m.insert("wl_data_device_manager", |p| p.data_device());
    m.insert("xdg_wm_base", |p| p.toplevel().map(|_| ()));
    m.insert("zxdg_decoration_manager_v1", |p| p.decoration());
    m.insert("org_kde_kwin_server_decoration_manager", |p| p.kde_decoration());
    m.insert("zxdg_output_manager_v1", |p| p.xdg_output());
    m.insert("wp_viewporter", |p| p.viewport());
    m.insert("wp_fractional_scale_manager_v1", |p| p.fractional_scale());
    m.insert("wp_cursor_shape_manager_v1", |p| p.cursor_shape());
    m.insert("wp_presentation", |p| p.presentation());
    m.insert("zwp_linux_dmabuf_v1", |p| p.dmabuf());
    m.insert("zwp_relative_pointer_manager_v1", |p| p.relative_pointer());
    m.insert("zwp_pointer_constraints_v1", |p| p.pointer_constraints());
    m.insert("zwp_pointer_gestures_v1", |p| p.pointer_gestures());
    m.insert("zwp_primary_selection_device_manager_v1", |p| p.primary_selection());
    m.insert("zwp_tablet_manager_v2", |p| p.tablet());
    m.insert("zwp_text_input_manager_v3", |p| p.text_input());
    m.insert("xdg_toplevel_icon_manager_v1", |p| p.toplevel_icon());
    m.insert("zwp_idle_inhibit_manager_v1", |p| p.idle_inhibit().map(|_| ()));
    m.insert("wp_content_type_manager_v1", |p| p.content_type(wayland_protocols::wp::content_type::v1::client::wp_content_type_v1::Type::Video).map(|_| ()));
    m.insert("xdg_activation_v1", |p| p.activation_token().map(|_| ()));
    m.insert("zwp_keyboard_shortcuts_inhibit_manager_v1", |p| p.shortcuts_inhibitor().map(|_| ()));
    m
}

/// Globals that exist only where the machine has what they need (linux-dmabuf: a render
/// node's formats). When advertised they are checked like any other.
const CONDITIONAL: &[&str] = &["zwp_linux_dmabuf_v1"];

/// Globals only Xwayland may see (the compositor shows them to no one else), and how they
/// are checked: by an X11 client that uses them.
const XWAYLAND_ONLY: &[&str] = &["xwayland_shell_v1", "zwp_xwayland_keyboard_grab_manager_v1"];

#[test]
fn every_advertised_global_is_serviceable() {
    let Some(server) = Server::start(false) else { return };
    let probe = Probe::connect(&server);
    let advertised = probe.globals();
    assert!(!advertised.is_empty(), "the compositor advertised nothing");
    let checks = checks();
    let mut failures = Vec::new();
    for (interface, version) in &advertised {
        match checks.get(interface.as_str()) {
            None => failures.push(format!("{interface} v{version} is advertised and nothing checks it")),
            Some(check) => {
                // Each check on its own connection: one global's failure is not another's.
                let mut p = Probe::connect(&server);
                if let Err(e) = check(&mut p).and_then(|_| p.roundtrip()) {
                    failures.push(format!("{interface} v{version}: {e}"));
                }
            }
        }
    }
    // A check for something not advertised is a stale check: remove it with the global.
    for interface in checks.keys() {
        if !advertised.iter().any(|(i, _)| i == interface) && !CONDITIONAL.contains(interface) {
            failures.push(format!("{interface} has a check but is not advertised"));
        }
    }
    assert!(failures.is_empty(), "\n{}\n(advertised: {advertised:?})", failures.join("\n"));
}

#[test]
fn xwayland_only_globals_are_advertised_to_xwayland_and_it_uses_them() {
    let Some(server) = Server::start(true) else { return };
    // Xwayland binds them at start: the compositor's wire log names each one it was sent.
    let log = server.wire_log();
    for interface in XWAYLAND_ONLY {
        assert!(log.contains(&format!("\"{interface}\"")), "{interface} is never offered to Xwayland");
    }
    // And Xwayland's keyboard grab reaches the phone: an X11 client's XGrabKeyboard.
    let mut phone = Phone::connect(&server, Phone::all());
    let grabber = XGrabber::start(&server);
    let id = phone.wait_window(|w| w.xwayland).expect("the X11 window is announced");
    phone.send(Message::Configure(proto::Configure { id, activated: Some(true), ..Default::default() }));
    phone.sync();
    grabber.grab();
    phone.wait_hint(id, |w| w.keys_grabbed == Some(true))
        .expect("an X11 keyboard grab reaches the phone as keys_grabbed");
    grabber.release();
    phone.wait_hint(id, |w| w.keys_grabbed == Some(false)).expect("releasing it clears keys_grabbed");
}

#[test]
fn every_feature_bit_is_documented_and_serviceable() {
    let Some(server) = Server::start(true) else { return };
    let docs = std::fs::read_to_string(docs_path("display.md")).expect("docs/display.md");
    let globals: Vec<String> = Probe::connect(&server).globals().into_iter().map(|(i, _)| i).collect();
    let has = |g: &str| globals.iter().any(|i| i == g);

    let mut phone = Phone::connect(&server, Phone::all());
    let features = phone.features.clone();
    assert!(!features.is_empty());
    let mut failures = Vec::new();
    for feature in &features {
        if !docs.contains(&format!("`{feature}`")) {
            failures.push(format!("{feature}: advertised, not documented in docs/display.md"));
        }
        let backed = match feature.as_str() {
            "vsync" => phone.vsync_releases_frame_callbacks(&server),
            "touch" => Probe::connect(&server).has_capability("touch"),
            "pencil" => has("zwp_tablet_manager_v2"),
            "text-input-v3" => has("zwp_text_input_manager_v3"),
            "cursor-named" => has("wp_cursor_shape_manager_v1"),
            "clipboard" | "clipboard-types" | "drop" | "drag" => has("wl_data_device_manager"),
            "gestures" => has("zwp_pointer_gestures_v1"),
            "window-hints" => {
                has("zwp_idle_inhibit_manager_v1") && has("wp_content_type_manager_v1") && has("xdg_activation_v1")
                    && has("zwp_keyboard_shortcuts_inhibit_manager_v1")
            }
            "xwayland" => server.x_socket_exists(),
            "audio" => server.pulse_socket_exists(),
            // Present only because the hello asked and the server can: see the absence check below.
            "wasm" | "webview" | "devices" | "targets" => true,
            other => {
                failures.push(format!("{other}: advertised and nothing checks it"));
                true
            }
        };
        if !backed {
            failures.push(format!("{feature}: advertised but its counterpart does not work"));
        }
    }
    // A feature that needs the client's say-so is absent without it.
    let bare = Phone::connect(&server, Phone::bare());
    for gated in ["wasm", "webview", "devices", "targets"] {
        if bare.features.iter().any(|f| f == gated) {
            failures.push(format!("{gated}: advertised to a client that did not ask for it"));
        }
    }
    assert!(failures.is_empty(), "\n{}\n(features: {features:?})", failures.join("\n"));
}

#[test]
fn hints_reach_the_phone() {
    let Some(server) = Server::start(false) else { return };
    let mut phone = Phone::connect(&server, Phone::all());
    let mut client = Probe::connect(&server);
    let window = client.toplevel().expect("toplevel");
    let id = phone.wait_window(|_| true).expect("the window is announced");

    // Idle inhibition follows the inhibitor.
    let created = phone.created(id).expect("announced");
    assert!(!created.idle_inhibit && created.content_type == ContentType::None && !created.keys_grabbed);
    let inhibitor = client.idle_inhibit_on(&window).expect("inhibitor");
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.idle_inhibit == Some(true)).expect("idle_inhibit true");
    inhibitor.destroy();
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.idle_inhibit == Some(false)).expect("idle_inhibit false");

    // Content type follows the surface's declaration.
    use wayland_protocols::wp::content_type::v1::client::wp_content_type_v1::Type;
    let content = client.content_type_on(&window, Type::Game).expect("content type");
    window.commit();
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.content_type == Some(ContentType::Game)).expect("game");
    content.set_content_type(Type::Video);
    window.commit();
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.content_type == Some(ContentType::Video)).expect("video");
    content.set_content_type(Type::None);
    window.commit();
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.content_type == Some(ContentType::None)).expect("none");

    // A keyboard shortcuts inhibitor is a keyboard grab the phone must honour.
    let shortcuts = client.shortcuts_inhibitor_on(&window).expect("shortcuts inhibitor");
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.keys_grabbed == Some(true)).expect("keys_grabbed true");
    shortcuts.destroy();
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.keys_grabbed == Some(false)).expect("keys_grabbed false");

    // A dead client's inhibitor does not keep the screen awake: the window goes with it.
    let inhibitor = client.idle_inhibit_on(&window).expect("inhibitor");
    let _ = inhibitor;
    client.roundtrip().unwrap();
    phone.wait_hint(id, |w| w.idle_inhibit == Some(true)).expect("idle again");
    drop(client);
    phone.wait_destroyed(id).expect("the window goes with its client");
}

#[test]
fn activation_follows_the_focused_application_only() {
    let Some(server) = Server::start(false) else { return };
    let mut phone = Phone::connect(&server, Phone::all());
    let mut focused = Probe::connect(&server);
    let a = focused.toplevel().expect("first window");
    let a_id = phone.wait_window(|_| true).expect("first announced");
    phone.send(Message::Configure(proto::Configure { id: a_id, activated: Some(true), ..Default::default() }));
    phone.sync();

    // The focused application makes a token, then launches another with it.
    let token = focused.activation_token_for(&a).expect("token");
    let mut other = Probe::connect(&server);
    let b = other.toplevel().expect("second window");
    let b_id = phone.wait_window(|w| w.id != a_id).expect("second announced");
    other.activate(&token, &b).expect("activate");
    other.roundtrip().unwrap();
    if phone.wait_activate(b_id).is_none() {
        let log = server.log_text();
        let tail: Vec<&str> = log.lines().rev().take(25).collect();
        panic!("a focused application's token brings a window forward\n{}", tail.into_iter().rev().collect::<Vec<_>>().join("\n"));
    }

    // A token made while another application holds the keyboard does nothing.
    phone.send(Message::Configure(proto::Configure { id: a_id, activated: Some(true), ..Default::default() }));
    phone.sync();
    let stray = other.activation_token_for(&b).expect("token");
    focused.activate(&stray, &a).expect("activate");
    focused.roundtrip().unwrap();
    assert!(phone.no_activate_within(Duration::from_millis(700)), "an application without the keyboard took the screen");
}
