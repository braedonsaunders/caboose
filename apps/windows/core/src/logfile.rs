//! Plain-text logs in `%LOCALAPPDATA%\Caboose\logs`, one timestamped line per event, with the
//! previous file kept as `<name>.1` once a log passes 5 MB.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_BYTES: u64 = 5 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Log {
    path: PathBuf,
}

impl Log {
    /// `<directory>\<name>.log`; the directory is created on the first write.
    pub fn new(directory: impl AsRef<Path>, name: &str) -> Log {
        Log { path: directory.as_ref().join(format!("{name}.log")) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Appends one line. Logging never fails the caller: a log that cannot be written is skipped.
    pub fn line(&self, message: impl AsRef<str>) {
        if let Some(directory) = self.path.parent() {
            let _ = fs::create_dir_all(directory);
        }
        if fs::metadata(&self.path).is_ok_and(|meta| meta.len() > MAX_BYTES) {
            let _ = fs::rename(&self.path, self.path.with_extension("log.1"));
        }
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&self.path) {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let _ = writeln!(file, "{} {}", timestamp(now), message.as_ref().trim_end());
        }
    }
}

/// Unix seconds as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn timestamp(unix_seconds: u64) -> String {
    let days = (unix_seconds / 86_400) as i64;
    let seconds = unix_seconds % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_utc_timestamps() {
        assert_eq!(timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(timestamp(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(timestamp(1_793_189_045), "2026-10-28T12:04:05Z");
    }

    #[test]
    fn appends_lines() {
        let directory = std::env::temp_dir().join(format!("caboose-log-test-{}", std::process::id()));
        let log = Log::new(&directory, "test");
        log.line("first\n");
        log.line("second");
        let text = fs::read_to_string(log.path()).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].ends_with("Z first") && lines[1].ends_with("Z second"));
        fs::remove_dir_all(directory).unwrap();
    }
}
