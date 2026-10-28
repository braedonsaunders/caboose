//! The "Caboose" scheduled task, which starts caboose-service at boot without anyone signing
//! in. WSL distributions belong to a user and do not run as LocalSystem, so the task runs as
//! the user who installed Caboose with the S4U logon type: Windows logs the user on without a
//! password (none is stored) and the task reaches only this PC's resources, which is all it needs.

/// What the task runs, and as whom.
pub struct TaskSpec<'a> {
    /// The user's SID (`S-1-5-21-…`), which survives a rename.
    pub user_sid: &'a str,
    pub command: &'a str,
    pub arguments: &'a str,
    pub working_directory: &'a str,
}

/// The task's definition for `schtasks /Create /XML`. It starts at boot and again every five
/// minutes (a second copy is never started, so this only revives a service that died), runs
/// with the user's highest privileges so the service can manage port forwarding, never stops
/// for batteries, idleness or a time limit, and restarts after a failure.
pub fn task_xml(spec: &TaskSpec<'_>) -> String {
    let user = xml_escape(spec.user_sid);
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Caboose</Author>
    <Description>Keeps Caboose's WSL distribution and caboose-host running, from boot, whether or not anyone is signed in.</Description>
    <URI>\{name}</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </BootTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{user}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{command}</Command>
      <Arguments>{arguments}</Arguments>
      <WorkingDirectory>{directory}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"#,
        name = xml_escape(crate::TASK_NAME),
        command = xml_escape(spec.command),
        arguments = xml_escape(spec.arguments),
        directory = xml_escape(spec.working_directory),
    )
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

/// UTF-16 little-endian with a byte order mark, the encoding `schtasks /XML` reads.
pub fn utf16le_with_bom(text: &str) -> Vec<u8> {
    let mut bytes = vec![0xFF, 0xFE];
    bytes.extend(text.encode_utf16().flat_map(u16::to_le_bytes));
    bytes
}

/// One argument quoted for a Windows command line, as `CommandLineToArgvW` splits it.
pub fn quote_argument(argument: &str) -> String {
    if !argument.is_empty() && !argument.contains([' ', '\t', '\n', '"']) {
        return argument.to_string();
    }
    let mut quoted = String::from('"');
    let mut backslashes = 0;
    for c in argument.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.push_str(&"\\".repeat(backslashes));
                quoted.push(c);
                backslashes = 0;
            }
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

/// The signed-in user's name and SID from `whoami /user /fo csv /nh`
/// (`"desktop\braedon","S-1-5-21-…"`).
pub fn parse_whoami_user(output: &str) -> Option<(String, String)> {
    let line = output.lines().map(str::trim).find(|line| !line.is_empty())?;
    let fields: Vec<&str> = line.split("\",\"").map(|field| field.trim_matches('"')).collect();
    let [name, sid] = fields[..] else { return None };
    sid.starts_with("S-1-").then(|| (name.to_string(), sid.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_an_s4u_boot_task() {
        let xml = task_xml(&TaskSpec {
            user_sid: "S-1-5-21-1-2-3-1001",
            command: r"C:\Users\Ann & Bo\AppData\Local\Caboose\bin\caboose-service.exe",
            arguments: r#"--home "C:\Users\Ann & Bo\AppData\Local\Caboose""#,
            working_directory: r"C:\Users\Ann & Bo\AppData\Local\Caboose",
        });
        assert!(xml.contains("<LogonType>S4U</LogonType>"));
        assert!(xml.contains("<BootTrigger>"));
        assert!(xml.contains("<UserId>S-1-5-21-1-2-3-1001</UserId>"));
        assert!(xml.contains("<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"));
        assert!(xml.contains("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"));
        assert!(xml.contains(r"<Command>C:\Users\Ann &amp; Bo\AppData\Local\Caboose\bin\caboose-service.exe</Command>"));
        assert!(xml.contains(r"<Arguments>--home &quot;C:\Users\Ann &amp; Bo\AppData\Local\Caboose&quot;</Arguments>"));
        assert!(!xml.contains("Password"));
    }

    #[test]
    fn encodes_utf16_with_a_bom() {
        assert_eq!(utf16le_with_bom("<é"), vec![0xFF, 0xFE, b'<', 0, 0xE9, 0]);
    }

    #[test]
    fn quotes_arguments_for_windows() {
        assert_eq!(quote_argument(r"C:\Caboose\bin"), r"C:\Caboose\bin");
        assert_eq!(quote_argument(r"C:\Program Files\Caboose\"), r#""C:\Program Files\Caboose\\""#);
        assert_eq!(quote_argument(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(quote_argument(""), r#""""#);
    }

    #[test]
    fn reads_whoami() {
        assert_eq!(
            parse_whoami_user("\"desktop-7\\braedon\",\"S-1-5-21-3623811015-3361044348-30300820-1013\"\r\n"),
            Some(("desktop-7\\braedon".into(), "S-1-5-21-3623811015-3361044348-30300820-1013".into()))
        );
        assert_eq!(parse_whoami_user("ERROR: Access denied"), None);
    }
}
