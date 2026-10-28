//! The firewall rules that let the LAN reach port 7310: Windows Firewall's, and with mirrored
//! networking the Hyper-V firewall's, which filters traffic into WSL. Both are limited to the
//! Private profile, so a network Windows treats as public (a café's) cannot reach Caboose.

/// The Windows Firewall rule's name, and the Hyper-V firewall rule's.
pub const RULE_NAME: &str = "Caboose";
/// WSL's VM creator id, which Hyper-V firewall rules for WSL name.
pub const WSL_VM_CREATOR_ID: &str = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}";

/// `netsh` arguments that remove the Windows Firewall rule (it fails harmlessly when absent).
pub fn delete_rule() -> Vec<String> {
    ["advfirewall", "firewall", "delete", "rule", &format!("name={RULE_NAME}")].map(String::from).to_vec()
}

/// `netsh` arguments that add the Windows Firewall rule for TCP `port` on the Private profile.
pub fn add_rule(port: u16) -> Vec<String> {
    [
        "advfirewall",
        "firewall",
        "add",
        "rule",
        &format!("name={RULE_NAME}"),
        "dir=in",
        "action=allow",
        "protocol=TCP",
        &format!("localport={port}"),
        "profile=private",
        "description=Caboose: the console and the iPhone app on your local network",
    ]
    .map(String::from)
    .to_vec()
}

/// A PowerShell script that replaces the Hyper-V firewall rule for TCP `port` on the Private
/// profile, on Windows that has the Hyper-V firewall (Windows 11 22H2 and later). Elsewhere
/// it does nothing.
pub fn hyperv_rule_script(port: u16) -> String {
    format!(
        "$ErrorActionPreference = 'Stop'; \
         if (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {{ \
           Get-NetFirewallHyperVRule -Name '{RULE_NAME}' -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule; \
           New-NetFirewallHyperVRule -Name '{RULE_NAME}' -DisplayName 'Caboose' -Direction Inbound \
             -VMCreatorId '{WSL_VM_CREATOR_ID}' -Protocol TCP -LocalPorts {port} -Profiles Private -Action Allow | Out-Null \
         }}"
    )
}

/// A PowerShell script that removes the Hyper-V firewall rule, if there is one.
pub fn remove_hyperv_rule_script() -> String {
    format!(
        "if (Get-Command Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {{ \
           Get-NetFirewallHyperVRule -Name '{RULE_NAME}' -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule \
         }}"
    )
}

/// A PowerShell script that prints the category (`Public`, `Private`, `DomainAuthenticated`)
/// of each connected network, one per line.
pub const NETWORK_CATEGORIES_SCRIPT: &str =
    "Get-NetConnectionProfile | ForEach-Object { $_.NetworkCategory.ToString() }";

/// Whether any connected network is Public, where the Private-profile rules do not apply.
pub fn any_public_network(categories_output: &str) -> bool {
    categories_output.lines().any(|line| line.trim().eq_ignore_ascii_case("public"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_the_windows_firewall_rule() {
        let add = add_rule(7310);
        assert_eq!(add[..4], ["advfirewall", "firewall", "add", "rule"]);
        assert!(add.contains(&"name=Caboose".to_string()));
        assert!(add.contains(&"localport=7310".to_string()));
        assert!(add.contains(&"profile=private".to_string()));
        assert_eq!(delete_rule(), ["advfirewall", "firewall", "delete", "rule", "name=Caboose"]);
    }

    #[test]
    fn builds_the_hyperv_rule_for_wsl() {
        let script = hyperv_rule_script(7310);
        assert!(script.contains("-VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'"));
        assert!(script.contains("-LocalPorts 7310 -Profiles Private"));
        assert!(script.starts_with("$ErrorActionPreference"));
        assert!(remove_hyperv_rule_script().contains("Remove-NetFirewallHyperVRule"));
    }

    #[test]
    fn notices_public_networks() {
        assert!(any_public_network("Private\r\nPublic\r\n"));
        assert!(!any_public_network("Private\nDomainAuthenticated\n"));
        assert!(!any_public_network(""));
    }
}
