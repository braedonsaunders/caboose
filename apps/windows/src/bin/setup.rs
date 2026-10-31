#![cfg_attr(windows, windows_subsystem = "windows")]
#[cfg(not(windows))]
fn main() {
    eprintln!("CabooseSetup runs on Windows 11.");
}
#[cfg(windows)]
fn main() {
    if let Err(error) = windows::launch() {
        eprintln!("{error}");
    }
}
#[cfg(windows)]
mod windows {
    use caboose_windows::{pairing_link, run, wsl, VERSION};
    use eframe::egui;
    use serde_json::{json, Value};
    use std::{
        path::PathBuf,
        sync::mpsc,
        time::{Duration, Instant},
    };
    use tray_icon::{
        menu::{Menu, MenuEvent, MenuItem},
        TrayIconBuilder,
    };
    const AGENT: &[u8] = include_bytes!(env!("CABOOSE_AGENT_PATH"));
    #[derive(Default)]
    struct Snapshot {
        reach: Value,
        image: Value,
        phones: Vec<Value>,
        claimed: bool,
    }
    enum Action {
        Refresh,
        Pair,
        Tailscale,
        Install(bool, bool),
        Open,
    }
    enum Reply {
        Snapshot(Snapshot),
        Code(Value),
        Message(String),
        Error(String),
    }
    fn directory() -> PathBuf {
        PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap()).join("Caboose")
    }
    fn api(method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        let token = wsl(&["cat", "/var/lib/caboose/disks/owner-token"])?;
        if token.is_empty() || token.contains(['\r', '\n']) {
            return Err("Host has not created its local credentials yet.".into());
        }
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(35))
            .build();
        let req = agent
            .request(method, &format!("http://127.0.0.1:7310{path}"))
            .set("Authorization", &format!("Bearer {token}"));
        let response = if let Some(body) = body {
            req.send_json(body)
        } else {
            req.call()
        }
        .map_err(|e| e.to_string())?;
        response.into_json().map_err(|e| e.to_string())
    }
    fn snapshot() -> Result<Snapshot, String> {
        Ok(Snapshot {
            reach: api("GET", "/v1/host/reach", None)?,
            image: api("GET", "/v1/health", None)?["image"].clone(),
            phones: api("GET", "/v1/computers/owner/phones", None)?["phones"]
                .as_array()
                .cloned()
                .unwrap_or_default(),
            claimed: api("GET", "/v1/setup", None)?["claimed"]
                .as_bool()
                .unwrap_or(false),
        })
    }
    fn write_payload() -> Result<(), String> {
        let root = directory();
        std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
        let source = std::env::current_exe().map_err(|e| e.to_string())?;
        let destination = root.join(format!("CabooseSetup-{VERSION}.exe"));
        if source != destination && !destination.exists() {
            std::fs::copy(&source, &destination).map_err(|e| e.to_string())?;
        }
        for (name, data) in [
            ("agent-payload.exe", AGENT),
            ("setup-wsl.ps1", caboose_windows::NETWORK.as_bytes()),
            ("start-wsl.ps1", caboose_windows::START.as_bytes()),
            ("install.ps1", caboose_windows::INSTALL.as_bytes()),
            (
                "linux-install.sh",
                caboose_windows::LINUX_INSTALL.as_bytes(),
            ),
        ] {
            let next = root.join(format!("{name}.new"));
            std::fs::write(&next, data).map_err(|e| e.to_string())?;
            std::fs::rename(&next, root.join(name)).map_err(|e| e.to_string())?;
        }
        let sid = run(
            "whoami.exe",
            &["/user", "/fo", "csv", "/nh"],
            Duration::from_secs(15),
        )?;
        let sid = sid.split(',').last().unwrap_or("").trim_matches('"').trim();
        if !sid.starts_with("S-1-5-") {
            return Err("Cannot determine Windows user identity".into());
        }
        std::fs::write(root.join("owner-sid"), sid).map_err(|e| e.to_string())
    }
    fn elevated(uninstall: bool, purge: bool) -> Result<String, String> {
        write_payload()?;
        let root = directory();
        // Quote the complete PowerShell argument string, preserving spaces in user paths.
        fn ps(s: &str) -> String {
            format!("'{}'", s.replace('\'', "''"))
        }
        let flags = if uninstall {
            if purge {
                " -Uninstall -Purge"
            } else {
                " -Uninstall"
            }
        } else {
            ""
        };
        let arguments = format!(
            "-NoProfile -ExecutionPolicy Bypass -File \"{}\" -Version {}{}",
            root.join("install.ps1").display(),
            VERSION,
            flags
        );
        let command = format!("$p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList {}; if ($p.ExitCode -eq 3010) {{ Write-Output 'Restart Windows, then open Caboose to finish.'; exit 0 }}; if ($p.ExitCode -ne 0) {{ throw 'Installation failed. See the elevated installer window for the failed step.' }}; Write-Output 'Installation finished.'",ps(&arguments));
        run(
            "powershell.exe",
            &["-NoProfile", "-NonInteractive", "-Command", &command],
            Duration::from_secs(3600),
        )
        .map_err(|error| std::fs::read_to_string(root.join("install-error.txt")).unwrap_or(error))
    }
    fn open_console() -> Result<(), String> {
        let code = wsl(&["cat", "/var/lib/caboose/disks/setup-code"]).ok();
        let mut url = url::Url::parse("http://127.0.0.1:7310/").unwrap();
        if let Some(code) = code.filter(|c| !c.is_empty()) {
            url.set_path("/setup");
            url.query_pairs_mut().append_pair("code", &code);
        }
        run(
            "rundll32.exe",
            &["url.dll,FileProtocolHandler", url.as_str()],
            Duration::from_secs(15),
        )?;
        Ok(())
    }
    struct App {
        tx: mpsc::Sender<Action>,
        rx: mpsc::Receiver<Reply>,
        state: Snapshot,
        code: Option<Value>,
        known: Vec<String>,
        paired: Option<String>,
        error: Option<String>,
        message: String,
        busy: bool,
        last: Instant,
        texture: Option<egui::TextureHandle>,
        last_link: String,
        tray: tray_icon::TrayIcon,
        show: MenuItem,
        console: MenuItem,
        quit: MenuItem,
        visible: bool,
        purge: bool,
        quitting: bool,
        initial_pair: bool,
    }
    impl App {
        fn send(&mut self, action: Action) {
            if !self.busy {
                self.busy = self.tx.send(action).is_ok();
            }
        }
    }
    impl eframe::App for App {
        fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
            while let Ok(event) = MenuEvent::receiver().try_recv() {
                if event.id == self.quit.id() {
                    if !self.busy {
                        self.quitting = true;
                        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    } else {
                        self.error = Some(
                            "Wait for the current operation to finish before quitting.".into(),
                        );
                    }
                }
                if event.id == self.console.id() {
                    self.send(Action::Open);
                }
                if event.id == self.show.id() {
                    self.visible = true;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                }
            }
            if !self.quitting && ctx.input(|i| i.viewport().close_requested()) {
                ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
                self.visible = false;
            }
            while let Ok(reply) = self.rx.try_recv() {
                self.busy = false;
                match reply {
                    Reply::Snapshot(s) => {
                        if self.code.is_some() {
                            for p in &s.phones {
                                let id = p["id"].as_str().unwrap_or("");
                                if !self.known.iter().any(|x| x == id) {
                                    self.paired =
                                        Some(p["name"].as_str().unwrap_or("iPhone").into());
                                    self.code = None;
                                }
                            }
                        }
                        self.state = s;
                        self.error = None;
                        self.message = "Host is running".into();
                        if !self.initial_pair {
                            self.initial_pair = true;
                            self.send(Action::Pair);
                        }
                    }
                    Reply::Code(c) => {
                        self.known = self
                            .state
                            .phones
                            .iter()
                            .filter_map(|p| p["id"].as_str().map(String::from))
                            .collect();
                        self.code = Some(c);
                        self.paired = None;
                        self.error = None;
                    }
                    Reply::Message(m) => {
                        self.message = m;
                        self.error = None;
                    }
                    Reply::Error(e) => self.error = Some(e),
                }
            }
            if self.visible && !self.busy && self.last.elapsed() > Duration::from_secs(2) {
                self.last = Instant::now();
                self.send(Action::Refresh);
            }
            let _ = self
                .tray
                .set_tooltip(Some(&format!("Caboose: {}", self.message)));
            egui::CentralPanel::default().show(ctx,|ui| {
        ui.heading("Caboose"); ui.label("Your phone’s computer."); ui.separator(); ui.label(&self.message);
        if let Some(error)=&self.error { ui.colored_label(egui::Color32::RED,error); }
        if self.busy { ui.spinner(); }
        ui.horizontal(|ui| {
            if ui.add_enabled(!self.busy,egui::Button::new("Install / Update Caboose")).clicked() { self.message="Installing Windows and Linux components…".into(); self.send(Action::Install(false,false)); }
            if ui.add_enabled(!self.busy,egui::Button::new("Open Web Console")).clicked() { self.send(Action::Open); }
        });
        if !self.state.claimed { ui.label("Open Web Console to create your account and household."); }
        if let Some(name)=&self.paired { ui.label(format!("✓ {name} is connected")); }
        ui.separator(); ui.heading("Pair your iPhone");
        if ui.add_enabled(!self.busy,egui::Button::new("New pairing code")).clicked() { self.send(Action::Pair); }
        if let Some(code)=&self.code {
            let addresses: Vec<String>=self.state.reach["addresses"].as_array().into_iter().flatten().filter_map(|a|a["url"].as_str().map(String::from)).collect();
            let value=code["code"].as_str().unwrap_or("");
            let expires = code["expiresAt"].as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()).map(|d|d.timestamp()).unwrap_or(0);
            let expired = expires <= std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
            if expired { ui.label("Code expired. Make a new code."); }
            else { match pairing_link(&addresses,value) {
                Ok(link)=>{
                    if link!=self.last_link { if let Ok(qr)=qrcode::QrCode::new(&link) {
                        let side=qr.width()+8; let mut pixels=vec![egui::Color32::WHITE;side*side];
                        for y in 0..qr.width() { for x in 0..qr.width() { if qr[(x,y)]==qrcode::Color::Dark { pixels[(y+4)*side+x+4]=egui::Color32::BLACK; } } }
                        self.texture=Some(ctx.load_texture("phone pairing",egui::ColorImage{size:[side,side],pixels},egui::TextureOptions::NEAREST)); self.last_link=link.clone();
                    } }
                    if let Some(texture)=&self.texture { ui.image((texture.id(),egui::vec2(240.,240.))); }
                    ui.label("Scan with the iPhone camera. The code works once, for ten minutes.");
                    ui.monospace(format!("{}-{}",&value[..4],&value[4..]));
                    if ui.button("Copy pairing link").clicked() { ui.ctx().copy_text(link); }
                }, Err(error)=>{ui.label(error);}
            } }
        }
        let image=&self.state.image;
        match image["state"].as_str() {
            Some("fetching") => { let total=image["totalBytes"].as_f64().unwrap_or(0.); let got=image["receivedBytes"].as_f64().unwrap_or(0.); if total>0. { ui.add(egui::ProgressBar::new((got/total).clamp(0.,1.) as f32).show_percentage().text("Downloading computer image")); } else { ui.spinner(); ui.label("Downloading computer image…"); } },
            Some("failed"|"missing")=>{ ui.label(image["message"].as_str().unwrap_or("Computer image unavailable")); },_=>{}
        }
        ui.separator(); ui.heading("Access away from home");
        let ts=&self.state.reach["tailscale"];
        if ts["serving"].as_bool()==Some(true) { ui.label(ts["httpsUrl"].as_str().unwrap_or("Tailscale HTTPS enabled")); }
        else if ts["installed"].as_bool()==Some(true) {
            if ui.add_enabled(!self.busy,egui::Button::new("Enable Tailscale HTTPS")).clicked() { self.send(Action::Tailscale); }
        } else { ui.hyperlink_to("Install Tailscale in the Caboose Linux distribution and on your iPhone","https://tailscale.com/download/linux"); }
        ui.collapsing("Uninstall",|ui| {
            ui.label("Removes startup and restores Windows networking. Computers remain in the Caboose distribution.");
            ui.checkbox(&mut self.purge,"Permanently delete the Caboose distribution and all its computers");
            if ui.add_enabled(!self.busy,egui::Button::new(if self.purge { "Delete all Caboose data and uninstall" } else { "Uninstall and keep computers" })).clicked() { self.send(Action::Install(true,self.purge)); }
        });
    });
            ctx.request_repaint_after(Duration::from_millis(200));
        }
    }
    pub fn launch() -> Result<(), String> {
        let args: Vec<_> = std::env::args().collect();
        if args.iter().any(|a| a == "--install" || a == "--uninstall") {
            elevated(
                args.iter().any(|a| a == "--uninstall"),
                args.iter().any(|a| a == "--purge"),
            )?;
            return Ok(());
        }
        let menu = Menu::new();
        let show = MenuItem::new("Pair iPhone…", true, None);
        let console = MenuItem::new("Open Web Console", true, None);
        let quit = MenuItem::new("Quit Caboose menu", true, None);
        menu.append_items(&[&show, &console, &quit])
            .map_err(|e| e.to_string())?;
        let mut rgba = vec![0u8; 32 * 32 * 4];
        for y in 5..27 {
            for x in 3..29 {
                let i = (y * 32 + x) * 4;
                rgba[i..i + 4].copy_from_slice(&[27, 43, 74, 255]);
            }
        }
        let icon = tray_icon::Icon::from_rgba(rgba, 32, 32).map_err(|e| e.to_string())?;
        let tray = TrayIconBuilder::new()
            .with_icon(icon)
            .with_tooltip("Caboose")
            .with_menu(Box::new(menu))
            .build()
            .map_err(|e| e.to_string())?;
        let (tx, requests) = mpsc::channel();
        let (replies, rx) = mpsc::channel();
        std::thread::spawn(move || {
            while let Ok(action) = requests.recv() {
                let result: Result<Reply, String> = (|| match action {
                    Action::Refresh => Ok(Reply::Snapshot(snapshot()?)),
                    Action::Pair => Ok(Reply::Code(api(
                        "POST",
                        "/v1/computers/owner/pairing",
                        None,
                    )?)),
                    Action::Tailscale => {
                        api(
                            "PUT",
                            "/v1/host/reach/tailscale",
                            Some(json!({"enabled":true})),
                        )?;
                        Ok(Reply::Snapshot(snapshot()?))
                    }
                    Action::Install(uninstall, purge) => {
                        Ok(Reply::Message(elevated(uninstall, purge)?))
                    }
                    Action::Open => {
                        open_console()?;
                        Ok(Reply::Message("Console opened".into()))
                    }
                })();
                if replies.send(result.unwrap_or_else(Reply::Error)).is_err() {
                    break;
                }
            }
        });
        let visible = !args.iter().any(|a| a == "--tray");
        eframe::run_native(
            "Caboose",
            eframe::NativeOptions {
                viewport: egui::ViewportBuilder::default()
                    .with_inner_size([540., 850.])
                    .with_visible(visible),
                ..Default::default()
            },
            Box::new(move |_| {
                Ok(Box::new(App {
                    tx,
                    rx,
                    state: Snapshot::default(),
                    code: None,
                    known: vec![],
                    paired: None,
                    error: None,
                    message: "Ready to install or connect to Caboose".into(),
                    busy: false,
                    last: Instant::now() - Duration::from_secs(5),
                    texture: None,
                    last_link: String::new(),
                    tray,
                    show,
                    console,
                    quit,
                    visible,
                    purge: false,
                    quitting: false,
                    initial_pair: false,
                }))
            }),
        )
        .map_err(|e| e.to_string())
    }
}
