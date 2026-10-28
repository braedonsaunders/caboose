//! Windows' port forwarding (`netsh interface portproxy`), which carries the LAN's
//! connections to port 7310 into the distribution when WSL uses NAT networking. With mirrored
//! networking the distribution listens on Windows' own interfaces and no rule may hold the port.

/// A `v4tov4` rule: connections to `listen` go to `connect`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub listen_address: String,
    pub listen_port: u16,
    pub connect_address: String,
    pub connect_port: u16,
}

impl Rule {
    /// Every interface's `port`, forwarded to the distribution's address.
    pub fn to_distro(distro_address: &str, port: u16) -> Rule {
        Rule {
            listen_address: "0.0.0.0".into(),
            listen_port: port,
            connect_address: distro_address.into(),
            connect_port: port,
        }
    }
}

/// The rules in `netsh interface portproxy show v4tov4`. Headings are translated in other
/// languages, so a rule is any line of exactly an address, a port, an address and a port.
pub fn parse_show(output: &str) -> Vec<Rule> {
    output
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let [listen_address, listen_port, connect_address, connect_port] = fields[..] else { return None };
            let looks_like_address = |text: &str| text.chars().all(|c| c.is_ascii_alphanumeric() || ".-:*".contains(c));
            if !looks_like_address(listen_address) || !looks_like_address(connect_address) {
                return None;
            }
            Some(Rule {
                listen_address: listen_address.to_string(),
                listen_port: listen_port.parse().ok()?,
                connect_address: connect_address.to_string(),
                connect_port: connect_port.parse().ok()?,
            })
        })
        .collect()
}

/// Changes only the exact rule recorded by Caboose. A foreign rule on the port is a conflict.
pub fn plan(desired: Option<&Rule>, existing: &[Rule], owned: Option<&Rule>) -> Result<Vec<Vec<String>>, String> {
    let mut commands = Vec::new();
    let mut satisfied = false;
    for rule in existing {
        if Some(rule) == desired && Some(rule) == owned {
            satisfied = true;
            continue;
        }
        if Some(rule) == owned {
            commands.push(netsh(&[
                "delete",
                "v4tov4",
                &format!("listenport={}", rule.listen_port),
                &format!("listenaddress={}", rule.listen_address),
            ]));
        } else if desired.is_some_and(|want| want.listen_port == rule.listen_port) {
            return Err(format!(
                "Port {} already has a Windows port proxy rule; remove or change it before using Caboose.",
                rule.listen_port
            ));
        }
    }
    if let (Some(rule), false) = (desired, satisfied) {
        commands.push(netsh(&[
            "add",
            "v4tov4",
            &format!("listenport={}", rule.listen_port),
            &format!("listenaddress={}", rule.listen_address),
            &format!("connectport={}", rule.connect_port),
            &format!("connectaddress={}", rule.connect_address),
        ]));
    }
    Ok(commands)
}

fn netsh(arguments: &[&str]) -> Vec<String> {
    ["interface", "portproxy"].iter().chain(arguments).map(|part| part.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHOW: &str = "\r\nListen on ipv4:             Connect to ipv4:\r\n\r\nAddress         Port        Address         Port\r\n--------------- ----------  --------------- ----------\r\n0.0.0.0         7310        172.22.48.10    7310\r\n0.0.0.0         8080        172.22.48.10    80\r\n\r\n";

    #[test]
    fn parses_netsh_output_in_any_language() {
        let rules = parse_show(SHOW);
        assert_eq!(
            rules,
            vec![
                Rule::to_distro("172.22.48.10", 7310),
                Rule { listen_port: 8080, connect_port: 80, ..Rule::to_distro("172.22.48.10", 0) }
            ]
        );
        let german = "Abfragen auf IPv4:           Verbinden mit IPv4:\n\nAdresse         Anschluss   Adresse         Anschluss\n--------------- ----------  --------------- ----------\n*               7310        localhost       7310\n";
        assert_eq!(parse_show(german)[0].listen_address, "*");
        assert!(parse_show("").is_empty());
    }

    #[test]
    fn adds_the_rule_when_there_is_none() {
        let desired = Rule::to_distro("172.22.48.10", 7310);
        assert_eq!(
            plan(Some(&desired), &[], None).unwrap(),
            vec![vec![
                "interface",
                "portproxy",
                "add",
                "v4tov4",
                "listenport=7310",
                "listenaddress=0.0.0.0",
                "connectport=7310",
                "connectaddress=172.22.48.10"
            ]]
        );
    }

    #[test]
    fn does_nothing_when_the_rule_is_current() {
        let desired = Rule::to_distro("172.22.48.10", 7310);
        assert!(plan(Some(&desired), &parse_show(SHOW), Some(&desired)).unwrap().is_empty());
    }

    #[test]
    fn replaces_a_rule_to_an_old_address() {
        let desired = Rule::to_distro("172.22.50.2", 7310);
        let commands = plan(Some(&desired), &parse_show(SHOW), Some(&Rule::to_distro("172.22.48.10", 7310))).unwrap();
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0][2..], ["delete", "v4tov4", "listenport=7310", "listenaddress=0.0.0.0"]);
        assert_eq!(commands[1][2], "add");
        assert_eq!(commands[1][7], "connectaddress=172.22.50.2");
    }

    #[test]
    fn preserves_foreign_rules() {
        let owned = Rule::to_distro("172.22.48.10", 7310);
        let foreign = Rule { listen_address: "192.168.1.20".into(), ..owned.clone() };
        let existing = vec![owned.clone(), foreign.clone()];
        assert_eq!(plan(None, &existing, Some(&owned)).unwrap().len(), 1);
        assert!(plan(Some(&Rule::to_distro("172.22.50.2", 7310)), &existing, Some(&owned)).is_err());
        assert!(plan(Some(&owned), &[foreign], None).is_err());
    }
}
