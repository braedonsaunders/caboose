//! What the Windows side knows about Caboose: the distribution's `caboose-wsl-ready` report,
//! caboose-host's `/v1/health`, the keepalive service's status file, and the one-line state
//! the tray shows for them.

use serde::{Deserialize, Serialize};

/// `caboose-wsl-ready`'s report (deploy/windows/distro).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WslReady {
    pub healthy: bool,
    #[serde(default)]
    pub service: Option<String>,
    pub url: String,
    #[serde(default)]
    pub port: Option<u16>,
    pub token_path: Option<String>,
    pub setup_code_path: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
}

/// The report in `caboose-wsl-ready`'s output: its last line that is a JSON object, so WSL's
/// own notices before it do not matter.
pub fn parse_ready(output: &str) -> Result<WslReady, String> {
    output
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| line.starts_with('{'))
        .ok_or_else(|| format!("caboose-wsl-ready printed no report: {}", output.trim()))
        .and_then(|line| {
            serde_json::from_str(line).map_err(|error| format!("caboose-wsl-ready's report is not valid: {error}"))
        })
}

/// The parts of `GET /v1/health` the tray shows (docs/architecture.md, "Session and display").
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    #[serde(default)]
    pub runtime: Option<String>,
    #[serde(default)]
    pub gpu: Option<String>,
    #[serde(default)]
    pub running: Option<bool>,
    #[serde(default)]
    pub image: Option<ImageStatus>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageStatus {
    pub state: String,
    #[serde(default)]
    pub received_bytes: Option<u64>,
    #[serde(default)]
    pub total_bytes: Option<u64>,
    #[serde(default)]
    pub message: Option<String>,
}

/// One `/v1/health` request's outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthCheck {
    Healthy(Health),
    /// 401 or 403: the token the tray read is not (or no longer) the owner token.
    Unauthorized,
    /// No owner token yet, and `GET /v1/setup` says nobody has claimed the host.
    Unclaimed,
    Unexpected(u16),
    /// No HTTP answer at all: the host or the distribution is not up.
    Unreachable(String),
}

impl HealthCheck {
    pub fn from_response(status: u16, body: &str) -> HealthCheck {
        match status {
            200 => match serde_json::from_str::<Health>(body) {
                Ok(health) => HealthCheck::Healthy(health),
                Err(_) => HealthCheck::Unexpected(status),
            },
            401 | 403 => HealthCheck::Unauthorized,
            other => HealthCheck::Unexpected(other),
        }
    }
}

/// Networking between Windows and the distribution.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Networking {
    /// WSL mirrors Windows' interfaces; the distribution's port 7310 is Windows' port 7310.
    Mirrored,
    /// WSL's NAT; caboose-service forwards Windows' port 7310 to the distribution.
    #[default]
    Nat,
}

/// What caboose-service writes to `service.json` every few seconds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceStatus {
    /// `holding` while the keepalive runs, `restarting` while it waits to start it again.
    pub state: String,
    pub networking: Networking,
    /// Unix seconds of the last write; a status older than [`STALE_AFTER_SECS`] is a dead service.
    pub updated_at: u64,
    pub restarts: u32,
    #[serde(default)]
    pub last_error: Option<String>,
    #[serde(default)]
    pub distro_address: Option<String>,
}

pub const STALE_AFTER_SECS: u64 = 90;

impl ServiceStatus {
    pub fn is_alive(&self, now: u64) -> bool {
        now.saturating_sub(self.updated_at) <= STALE_AFTER_SECS
    }
}

/// The tray's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Light {
    Running,
    Starting,
    Stopped,
    Problem,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrayStatus {
    pub light: Light,
    /// One line for the tooltip and the menu, such as "Caboose is running".
    pub summary: String,
}

/// What the tray says, from the service's status file (if it could be read) and a health check.
pub fn tray_status(service: Option<&ServiceStatus>, health: &HealthCheck, now: u64) -> TrayStatus {
    let (light, summary) = match health {
        HealthCheck::Healthy(health) => match health.image.as_ref().map(|image| (image.state.as_str(), image)) {
            Some(("fetching", image)) => (
                Light::Running,
                match (image.received_bytes, image.total_bytes) {
                    (Some(received), Some(total)) if total > 0 => {
                        format!("Downloading the computer's image ({}%)", received.saturating_mul(100) / total)
                    }
                    _ => "Downloading the computer's image".to_string(),
                },
            ),
            Some(("failed", image)) => (
                Light::Problem,
                format!(
                    "The computer's image failed to download{}",
                    image.message.as_deref().map(|m| format!(": {m}")).unwrap_or_default()
                ),
            ),
            _ if health.running == Some(true) => {
                (Light::Running, "Caboose is running; the computer is awake".to_string())
            }
            _ => (Light::Running, "Caboose is running".to_string()),
        },
        HealthCheck::Unclaimed => {
            (Light::Running, "Caboose is running: open the console to finish setting it up".to_string())
        }
        HealthCheck::Unauthorized => {
            (Light::Problem, "Caboose is running, but did not accept its owner token".to_string())
        }
        HealthCheck::Unexpected(status) => (Light::Problem, format!("caboose-host answered HTTP {status}")),
        HealthCheck::Unreachable(_) => match service.filter(|status| status.is_alive(now)) {
            Some(status) if status.state == "restarting" => (
                Light::Problem,
                status
                    .last_error
                    .clone()
                    .unwrap_or_else(|| "Caboose's distribution stopped; starting it again".to_string()),
            ),
            Some(_) => (Light::Starting, "Caboose is starting…".to_string()),
            None => (Light::Stopped, "Caboose is not running: its startup task is stopped".to_string()),
        },
    };
    TrayStatus { light, summary }
}

/// The console's address on this PC.
pub fn local_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}

/// The console's Host page, where remote access is set up.
pub fn host_page(base: &str) -> String {
    format!("{}/host", base.trim_end_matches('/'))
}

/// The console's first-run page for the host's one-time setup code, which the host writes to
/// `$CABOOSE_IMAGE_ROOT/setup-code` while nobody has claimed it.
pub fn first_run_url(base: &str, code: &str) -> String {
    format!("{}/setup?code={}", base.trim_end_matches('/'), crate::pairing::form_encode(code.trim()))
}

/// `GET /v1/setup`, which needs no token: whether the host has been claimed yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupState {
    pub claimed: bool,
    #[serde(default)]
    pub code_required: bool,
}

/// Where "Open console" goes: the first-run page while the host is unclaimed, with its setup
/// code when the code could be read; the console otherwise. `setup` is `GET /v1/setup`'s
/// answer when there was one; a code from the file is used unless the host says it is claimed.
pub fn console_entry(base: &str, setup_code: Option<&str>, setup: Option<SetupState>) -> String {
    let base = base.trim_end_matches('/');
    match (setup_code.map(str::trim).filter(|code| !code.is_empty()), setup) {
        (Some(code), None) | (Some(code), Some(SetupState { claimed: false, .. })) => first_run_url(base, code),
        (None, Some(SetupState { claimed: false, .. })) => format!("{base}/setup"),
        _ => base.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_caboose_wsl_ready() {
        let output = "wsl: A localhost proxy configuration was detected\n{\"healthy\":true,\"service\":\"active\",\"url\":\"http://127.0.0.1:7310\",\"port\":7310,\"tokenPath\":\"/var/lib/caboose/owner-token\",\"setupCodePath\":null,\"version\":\"v0.3.0\"}\n";
        let ready = parse_ready(output).unwrap();
        assert!(ready.healthy);
        assert_eq!(ready.url, "http://127.0.0.1:7310");
        assert_eq!(ready.token_path.as_deref(), Some("/var/lib/caboose/owner-token"));
        assert_eq!(ready.setup_code_path, None);
        assert_eq!(ready.version.as_deref(), Some("v0.3.0"));
        let minimal = parse_ready(r#"{"healthy":false,"url":"http://127.0.0.1:7310","tokenPath":null,"setupCodePath":"/var/lib/caboose/setup-code"}"#).unwrap();
        assert_eq!(minimal.setup_code_path.as_deref(), Some("/var/lib/caboose/setup-code"));
        assert!(parse_ready("").is_err());
        assert!(parse_ready("{not json").is_err());
    }

    #[test]
    fn classifies_health_responses() {
        let body = r#"{"host":"caboose-host","runtime":"container","gpu":"wsl","container":"caboose-owner","running":false,"machine":{"memoryMb":32000,"availableMemoryMb":20000,"cpus":16,"disk":null},"image":{"state":"ready","reference":"ghcr.io/x"}}"#;
        let HealthCheck::Healthy(health) = HealthCheck::from_response(200, body) else { panic!("healthy") };
        assert_eq!(health.gpu.as_deref(), Some("wsl"));
        assert_eq!(health.image.unwrap().state, "ready");
        assert_eq!(HealthCheck::from_response(401, r#"{"error":"unauthorized"}"#), HealthCheck::Unauthorized);
        assert_eq!(HealthCheck::from_response(403, ""), HealthCheck::Unauthorized);
        assert_eq!(HealthCheck::from_response(502, ""), HealthCheck::Unexpected(502));
        assert_eq!(HealthCheck::from_response(200, "<html>"), HealthCheck::Unexpected(200));
    }

    fn service(updated_at: u64, last_error: Option<&str>) -> ServiceStatus {
        ServiceStatus {
            state: "holding".into(),
            networking: Networking::Mirrored,
            updated_at,
            restarts: 0,
            last_error: last_error.map(str::to_string),
            distro_address: None,
        }
    }

    #[test]
    fn says_what_state_caboose_is_in() {
        let now = 1_000;
        let healthy = HealthCheck::Healthy(Health::default());
        assert_eq!(tray_status(None, &healthy, now).light, Light::Running);
        let fetching = HealthCheck::Healthy(Health {
            image: Some(ImageStatus {
                state: "fetching".into(),
                received_bytes: Some(42),
                total_bytes: Some(100),
                message: None,
            }),
            ..Health::default()
        });
        assert_eq!(tray_status(None, &fetching, now).summary, "Downloading the computer's image (42%)");
        let down = HealthCheck::Unreachable("refused".into());
        assert_eq!(tray_status(Some(&service(now - 5, None)), &down, now).light, Light::Starting);
        assert_eq!(tray_status(Some(&service(now - 500, None)), &down, now).light, Light::Stopped);
        assert_eq!(tray_status(None, &down, now).light, Light::Stopped);
        let failing = service(now, Some("wsl.exe exited: the distribution is not registered"));
        assert_eq!(tray_status(Some(&failing), &down, now).light, Light::Starting);
        let restarting = ServiceStatus { state: "restarting".into(), ..failing };
        let status = tray_status(Some(&restarting), &down, now);
        assert_eq!(
            (status.light, status.summary.as_str()),
            (Light::Problem, "wsl.exe exited: the distribution is not registered")
        );
        assert_eq!(tray_status(None, &HealthCheck::Unauthorized, now).light, Light::Problem);
        assert_eq!(tray_status(None, &HealthCheck::Unclaimed, now).light, Light::Running);
    }

    #[test]
    fn round_trips_the_service_status() {
        let status = service(5, Some("x"));
        let json = serde_json::to_string(&status).unwrap();
        assert!(json.contains("\"networking\":\"mirrored\"") && json.contains("\"updatedAt\":5"));
        assert_eq!(serde_json::from_str::<ServiceStatus>(&json).unwrap(), status);
    }

    #[test]
    fn builds_console_addresses() {
        assert_eq!(local_url(7310), "http://127.0.0.1:7310");
        assert_eq!(host_page("http://127.0.0.1:7310/"), "http://127.0.0.1:7310/host");
        assert_eq!(first_run_url("http://127.0.0.1:7310", " ABCD2345\n"), "http://127.0.0.1:7310/setup?code=ABCD2345");
    }

    #[test]
    fn opens_the_first_run_page_until_the_host_is_claimed() {
        let base = "http://127.0.0.1:7310";
        let unclaimed: SetupState = serde_json::from_str(r#"{"claimed":false,"codeRequired":true}"#).unwrap();
        let claimed = SetupState { claimed: true, code_required: false };
        assert_eq!(console_entry(base, Some("K7Q2M9XD\n"), None), "http://127.0.0.1:7310/setup?code=K7Q2M9XD");
        assert_eq!(console_entry(base, Some("K7Q2M9XD"), Some(unclaimed)), "http://127.0.0.1:7310/setup?code=K7Q2M9XD");
        assert_eq!(console_entry(base, Some("K7Q2M9XD"), Some(claimed)), base);
        assert_eq!(console_entry(base, None, Some(unclaimed)), "http://127.0.0.1:7310/setup");
        assert_eq!(console_entry(base, None, None), base);
        assert_eq!(console_entry(base, Some(" "), Some(claimed)), base);
    }
}
