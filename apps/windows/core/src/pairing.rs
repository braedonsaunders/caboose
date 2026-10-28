//! Signing an iPhone in: the `caboose://connect` link the iOS app opens, and the addresses on
//! this PC a phone can reach it at.

use serde::Deserialize;
use std::net::Ipv4Addr;

/// `POST /v1/computers/:id/pairing`'s answer (docs/architecture.md, "Computers").
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingCode {
    pub code: String,
    #[serde(default)]
    pub expires_at: Option<String>,
}

/// `application/x-www-form-urlencoded`, as the console's `URLSearchParams` writes it, so the
/// links match byte for byte: letters, digits and `*-._` stay, a space is `+`, the rest is
/// percent-encoded UTF-8.
pub fn form_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => out.push(byte as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// `caboose://connect?host=<url>&alt=<url>…&<credential>=<value>`: the first address is the
/// one the phone tries first, the rest are alternatives it races.
fn connect_link(addresses: &[String], credential: &str, value: &str) -> Option<String> {
    let (host, alternates) = addresses.split_first()?;
    let mut link = format!("caboose://connect?host={}", form_encode(host.trim_end_matches('/')));
    for alternate in alternates {
        link.push_str(&format!("&alt={}", form_encode(alternate.trim_end_matches('/'))));
    }
    link.push_str(&format!("&{credential}={}", form_encode(value.trim())));
    Some(link)
}

/// The link for a single-use pairing code. `None` without an address.
pub fn pairing_link(addresses: &[String], code: &str) -> Option<String> {
    connect_link(addresses, "code", code)
}

/// A code as people read it aloud: `ABCD-2345`.
pub fn format_code(code: &str) -> String {
    if code.len() == 8 && code.is_ascii() {
        format!("{}-{}", &code[..4], &code[4..])
    } else {
        code.to_string()
    }
}

/// An IPv4 address of one of this PC's network adapters that is up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Interface {
    pub name: String,
    pub address: Ipv4Addr,
}

/// The addresses a phone could reach this PC at, best first: the one Windows routes the
/// internet through, then other private LAN addresses, then CGNAT addresses such as
/// Tailscale's. Loopback, link-local and WSL's and Hyper-V's own virtual adapters are left out.
pub fn phone_addresses(interfaces: &[Interface], primary: Option<Ipv4Addr>) -> Vec<Ipv4Addr> {
    let virtual_adapter = |name: &str| name.contains("WSL") || name.contains("Default Switch");
    let usable: Vec<Ipv4Addr> = interfaces
        .iter()
        .filter(|interface| !virtual_adapter(&interface.name))
        .map(|interface| interface.address)
        .filter(|address| !address.is_loopback() && !address.is_link_local() && !address.is_unspecified())
        .collect();
    let cgnat = |address: &Ipv4Addr| address.octets()[0] == 100 && (64..128).contains(&address.octets()[1]);
    let mut ordered = Vec::new();
    if let Some(primary) = primary.filter(|primary| usable.contains(primary)) {
        ordered.push(primary);
    }
    ordered.extend(usable.iter().filter(|address| address.is_private()));
    ordered.extend(usable.iter().filter(|address| cgnat(address)));
    ordered.extend(usable.iter().filter(|address| !address.is_private() && !cgnat(address)));
    let mut seen = Vec::new();
    ordered.retain(|address| {
        let first = !seen.contains(address);
        seen.push(*address);
        first
    });
    ordered
}

/// The address Windows would send internet traffic from, found by asking the routing table
/// (connecting a UDP socket sends nothing).
pub fn primary_ipv4() -> Option<Ipv4Addr> {
    let socket = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect((Ipv4Addr::new(1, 1, 1, 1), 53)).ok()?;
    match socket.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(address) if !address.is_unspecified() => Some(address),
        _ => None,
    }
}

/// One of the addresses `GET /v1/host/reach` lists, best first (`kind` is `public`,
/// `tailscale` or `lan`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ReachAddress {
    pub url: String,
    #[serde(default)]
    pub kind: String,
}

/// `GET /v1/host/reach`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Reach {
    pub addresses: Vec<ReachAddress>,
}

/// The addresses for a pairing link: the host's own list (`/v1/host/reach`), best first. Under
/// WSL's NAT networking the host sees only its virtual network, so its LAN addresses are
/// replaced by this PC's (`windows_lan`), which port forwarding carries into it. Without the
/// host's list, this PC's LAN addresses are all there is.
pub fn pairing_addresses(reach: Option<&[ReachAddress]>, windows_lan: &[String], mirrored: bool) -> Vec<String> {
    let mut addresses: Vec<String> = Vec::new();
    match reach.filter(|reach| !reach.is_empty()) {
        Some(reach) => {
            let mut lan_added = false;
            for address in reach {
                if address.kind == "lan" && !mirrored {
                    if !lan_added {
                        addresses.extend(windows_lan.iter().cloned());
                        lan_added = true;
                    }
                } else {
                    addresses.push(address.url.trim_end_matches('/').to_string());
                }
            }
            if !mirrored && !lan_added {
                addresses.extend(windows_lan.iter().cloned());
            }
        }
        None => addresses.extend(windows_lan.iter().cloned()),
    }
    let mut seen = std::collections::HashSet::new();
    addresses.retain(|address| seen.insert(address.clone()));
    addresses
}

/// `http://<address>:<port>` for each address.
pub fn address_urls(addresses: &[Ipv4Addr], port: u16) -> Vec<String> {
    addresses.iter().map(|address| format!("http://{address}:{port}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_like_url_search_params() {
        assert_eq!(form_encode("https://computer.example.com"), "https%3A%2F%2Fcomputer.example.com");
        assert_eq!(form_encode("a b&c=d/é"), "a+b%26c%3Dd%2F%C3%A9");
        assert_eq!(form_encode("AZaz09*-._"), "AZaz09*-._");
    }

    #[test]
    fn builds_the_link_the_console_builds() {
        // apps/web/src/console.test.ts
        assert_eq!(
            pairing_link(&["https://computer.example.com/".into()], "ABCD2345").unwrap(),
            "caboose://connect?host=https%3A%2F%2Fcomputer.example.com&code=ABCD2345"
        );
    }

    #[test]
    fn adds_alternative_addresses() {
        let addresses = vec!["http://192.168.1.20:7310".to_string(), "http://100.101.102.103:7310".to_string()];
        assert_eq!(
            pairing_link(&addresses, "ABCD2345").unwrap(),
            "caboose://connect?host=http%3A%2F%2F192.168.1.20%3A7310&alt=http%3A%2F%2F100.101.102.103%3A7310&code=ABCD2345"
        );
        assert_eq!(pairing_link(&[], "ABCD2345"), None);
    }

    #[test]
    fn takes_the_hosts_addresses_and_this_pcs_lan_under_nat() {
        let reach: Reach = serde_json::from_str(
            r#"{"addresses":[{"url":"https://caboose.example.com","kind":"public"},{"url":"http://100.101.102.103:7310","kind":"tailscale"},{"url":"http://172.22.48.10:7310","kind":"lan"},{"url":"http://172.22.48.11:7310","kind":"lan"}],"mdns":null,"tailscale":null}"#,
        )
        .unwrap();
        let lan = vec!["http://192.168.1.20:7310".to_string(), "http://10.0.0.7:7310".to_string()];
        assert_eq!(
            pairing_addresses(Some(&reach.addresses), &lan, false),
            vec![
                "https://caboose.example.com",
                "http://100.101.102.103:7310",
                "http://192.168.1.20:7310",
                "http://10.0.0.7:7310"
            ]
        );
        assert_eq!(
            pairing_addresses(Some(&reach.addresses), &lan, true),
            vec![
                "https://caboose.example.com",
                "http://100.101.102.103:7310",
                "http://172.22.48.10:7310",
                "http://172.22.48.11:7310"
            ]
        );
        assert_eq!(
            pairing_addresses(Some(&reach.addresses[..1]), &lan[..1], false),
            vec!["https://caboose.example.com", "http://192.168.1.20:7310"]
        );
        assert_eq!(pairing_addresses(None, &lan, true), lan);
        assert_eq!(pairing_addresses(Some(&[]), &lan[..1], true), lan[..1].to_vec());
    }

    #[test]
    fn reads_the_pairing_endpoint_and_formats_codes() {
        let code: PairingCode =
            serde_json::from_str(r#"{"code":"ABCD2345","expiresAt":"2026-10-28T12:10:00.000Z"}"#).unwrap();
        assert_eq!(code.expires_at.as_deref(), Some("2026-10-28T12:10:00.000Z"));
        assert_eq!(format_code(&code.code), "ABCD-2345");
        assert_eq!(format_code("ABC"), "ABC");
    }

    #[test]
    fn orders_the_addresses_a_phone_can_reach() {
        let interface =
            |name: &str, address: [u8; 4]| Interface { name: name.into(), address: Ipv4Addr::from(address) };
        let interfaces = vec![
            interface("Loopback Pseudo-Interface 1", [127, 0, 0, 1]),
            interface("vEthernet (WSL (Hyper-V firewall))", [172, 22, 48, 1]),
            interface("Tailscale", [100, 101, 102, 103]),
            interface("Wi-Fi", [10, 0, 0, 7]),
            interface("Ethernet", [192, 168, 1, 20]),
            interface("Ethernet 2", [169, 254, 3, 4]),
        ];
        let ordered = phone_addresses(&interfaces, Some(Ipv4Addr::new(192, 168, 1, 20)));
        assert_eq!(
            ordered,
            vec![Ipv4Addr::new(192, 168, 1, 20), Ipv4Addr::new(10, 0, 0, 7), Ipv4Addr::new(100, 101, 102, 103)]
        );
        assert_eq!(phone_addresses(&interfaces, Some(Ipv4Addr::new(172, 22, 48, 1)))[0], Ipv4Addr::new(10, 0, 0, 7));
        assert_eq!(address_urls(&ordered[..1], 7310), vec!["http://192.168.1.20:7310"]);
    }
}
