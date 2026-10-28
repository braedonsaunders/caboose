//! The keepalive loop, the NAT port forwarder, and the status file.

use caboose_win_core::backoff::{delay, failures_after};
use caboose_win_core::layout::{InstallConfig, Layout};
use caboose_win_core::logfile::Log;
use caboose_win_core::portproxy::{self, Rule};
use caboose_win_core::process::{command, run_checked, system32};
use caboose_win_core::status::{Networking, ServiceStatus};
use caboose_win_core::wsl::{exec_as_root, parse_ipv4};
use caboose_win_core::PORT;
use std::io::{BufRead, BufReader, Read};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

const KEEPALIVE: &str = "/usr/local/bin/caboose-keepalive";
/// How often the status file is rewritten, so the tray can tell a live service from a dead one.
const HEARTBEAT: Duration = Duration::from_secs(15);
/// How often the forwarder checks the distribution's address under NAT.
const FORWARD_EVERY: Duration = Duration::from_secs(15);

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn main() -> i32 {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let home = match arguments.windows(2).find(|pair| pair[0] == "--home") {
        Some(pair) => PathBuf::from(&pair[1]),
        None => match std::env::var_os("LOCALAPPDATA") {
            Some(local) => Layout::new(local).root,
            None => return 2,
        },
    };
    let layout = Layout { root: home };
    let log = Log::new(layout.logs(), "service");

    // One service at a time: the lock file is opened without sharing for as long as it runs.
    let _lock = match std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .share_mode(0)
        .open(layout.root.join("service.lock"))
    {
        Ok(file) => file,
        Err(_) => {
            log.line("another caboose-service is running; exiting");
            return 0;
        }
    };

    let config = std::fs::read_to_string(layout.config())
        .ok()
        .and_then(|text| InstallConfig::parse(&text).map_err(|error| log.line(error)).ok())
        .unwrap_or_default();
    log.line(format!("caboose-service {} started ({:?} networking)", env!("CARGO_PKG_VERSION"), config.networking));

    let previous_address = std::fs::read_to_string(layout.service_status())
        .ok()
        .and_then(|text| serde_json::from_str::<ServiceStatus>(&text).ok())
        .and_then(|status| status.distro_address);
    let status = Arc::new(Mutex::new(ServiceStatus {
        state: "starting".into(),
        networking: config.networking,
        updated_at: now(),
        restarts: 0,
        last_error: None,
        distro_address: previous_address,
    }));
    {
        let status = status.clone();
        let path = layout.service_status();
        thread::spawn(move || loop {
            write_status(&path, &status);
            thread::sleep(HEARTBEAT);
        });
    }
    if config.networking == Networking::Nat {
        let status = status.clone();
        let log = log.clone();
        let path = layout.service_status();
        thread::spawn(move || forward(&log, &status, &path));
    }

    let job = kill_on_close_job(&log);
    let mut failures = 0;
    loop {
        update(&status, |status| status.state = "holding".into());
        write_status(&layout.service_status(), &status);
        let started = Instant::now();
        let outcome = keepalive(&log, job);
        let ran_for = started.elapsed();
        failures = failures_after(failures, ran_for);
        let wait = delay(failures);
        let message = format!(
            "the keepalive ended after {}s: {outcome}; starting it again in {}s",
            ran_for.as_secs(),
            wait.as_secs()
        );
        log.line(&message);
        update(&status, |status| {
            status.state = "restarting".into();
            status.restarts = status.restarts.saturating_add(1);
            status.last_error = Some(message);
        });
        write_status(&layout.service_status(), &status);
        thread::sleep(wait);
    }
}

fn update(status: &Mutex<ServiceStatus>, change: impl FnOnce(&mut ServiceStatus)) {
    if let Ok(mut status) = status.lock() {
        change(&mut status);
    }
}

/// Rewrites `service.json` (through a temporary file, so a reader never sees half of it).
fn write_status(path: &Path, status: &Mutex<ServiceStatus>) {
    let Ok(mut current) = status.lock() else { return };
    current.updated_at = now();
    let Ok(json) = serde_json::to_string(&*current) else { return };
    drop(current);
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, json).is_ok() {
        let _ = std::fs::rename(&temporary, path);
    }
}

/// A job that ends every process in it when this service ends, however it ends, so a
/// keepalive never outlives the service that started it.
fn kill_on_close_job(log: &Log) -> Option<HANDLE> {
    // SAFETY: creates and configures a job object owned by this process for its lifetime.
    unsafe {
        let job = CreateJobObjectW(None, None).map_err(|error| log.line(format!("no job object: {error}"))).ok()?;
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as *const core::ffi::c_void,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
        .map_err(|error| log.line(format!("job object limits: {error}")))
        .ok()?;
        Some(job)
    }
}

/// Runs the keepalive until it exits, logging what it and WSL print, and says how it ended.
fn keepalive(log: &Log, job: Option<HANDLE>) -> String {
    let mut child = match command(system32("wsl.exe"))
        .args(exec_as_root(KEEPALIVE, &[]))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => return format!("wsl.exe did not start: {error}"),
    };
    if let Some(job) = job {
        // SAFETY: the child's handle is valid while `child` lives.
        if let Err(error) = unsafe { AssignProcessToJobObject(job, HANDLE(child.as_raw_handle())) } {
            log.line(format!("the keepalive is not in the job object: {error}"));
        }
    }
    log.line(format!("started the keepalive (wsl.exe pid {})", child.id()));
    let readers: Vec<_> = [
        child.stdout.take().map(|out| Box::new(out) as Box<dyn Read + Send>),
        child.stderr.take().map(|err| Box::new(err) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    .map(|stream| {
        let log = log.clone();
        thread::spawn(move || {
            let mut last = String::new();
            for line in BufReader::new(stream).split(b'\n').map_while(Result::ok) {
                let text = caboose_win_core::wsl::decode_output(&line).trim().to_string();
                if !text.is_empty() {
                    log.line(format!("keepalive: {text}"));
                    last = text;
                }
            }
            last
        })
    })
    .collect();
    let status = child.wait();
    let said: Vec<String> =
        readers.into_iter().filter_map(|reader| reader.join().ok()).filter(|text| !text.is_empty()).collect();
    let code = match status {
        Ok(status) => status.code().map(|code| format!("exit code {code}")).unwrap_or_else(|| "stopped".into()),
        Err(error) => format!("lost track of it: {error}"),
    };
    match said.last() {
        Some(text) => format!("{code}, {text}"),
        None => code,
    }
}

/// Under NAT, keeps `0.0.0.0:7310` forwarded to the distribution's current address.
fn forward(log: &Log, status: &Mutex<ServiceStatus>, path: &Path) {
    let mut last_error = String::new();
    loop {
        let previous = status.lock().ok().and_then(|status| status.distro_address.clone());
        match forward_once(log, previous.as_deref()) {
            Ok(address) => {
                last_error.clear();
                update(status, |status| status.distro_address = Some(address));
                write_status(path, status);
            }
            Err(error) if error != last_error => {
                log.line(format!("port forwarding: {error}"));
                last_error = error;
            }
            Err(_) => {}
        }
        thread::sleep(FORWARD_EVERY);
    }
}

fn forward_once(log: &Log, previous: Option<&str>) -> Result<String, String> {
    let output =
        run_checked(system32("wsl.exe"), &exec_as_root("/usr/sbin/ip", &["-4", "-o", "addr", "show", "dev", "eth0"]))?;
    let address = parse_ipv4(&output.stdout)
        .ok_or_else(|| format!("the distribution has no IPv4 address: {}", output.stdout.trim()))?;
    let netsh = system32("netsh.exe");
    let shown = run_checked(&netsh, &["interface", "portproxy", "show", "v4tov4"])?;
    let desired = Rule::to_distro(&address.to_string(), PORT);
    let owned = previous.map(|address| Rule::to_distro(address, PORT));
    for change in portproxy::plan(Some(&desired), &portproxy::parse_show(&shown.stdout), owned.as_ref())? {
        log.line(format!("netsh {}", change.join(" ")));
        run_checked(&netsh, &change)?;
    }
    Ok(address.to_string())
}
