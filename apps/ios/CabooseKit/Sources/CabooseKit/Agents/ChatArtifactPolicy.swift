import Foundation

/// All guest paths are translated into home-relative file-service paths, never local URLs.
public enum ChatArtifactPolicy {
    /// WebKit content blockers do not support regular-expression alternation. Keep each
    /// scheme in its own rule; a rejected rule list prevents the isolated view loading.
    public static let contentRules = #"[{"trigger":{"url-filter":"^https?:","url-filter-is-case-sensitive":false},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:","url-filter-is-case-sensitive":false},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:","url-filter-is-case-sensitive":false},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:","url-filter-is-case-sensitive":false},"action":{"type":"block"}}]"#

    public static let maximumFileBytes = 25 * 1024 * 1024
    public static let maximumHTMLBytes = 512 * 1024
    public static let maximumComposeCharacters = 32_000

    public static func guestPath(_ destination: String) -> String? {
        guard !destination.isEmpty, destination.utf8.count <= 8192,
              let parts = URLComponents(string: destination), parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        var path: String
        if let scheme = parts.scheme {
            guard scheme.lowercased() == "file", parts.host == nil || parts.host == "" else { return nil }
            path = parts.path
        } else {
            guard parts.host == nil else { return nil }
            path = parts.path
        }
        if path.hasPrefix("/home/caboose/") { path.removeFirst("/home/caboose/".count) }
        else if path.hasPrefix("~/") { path.removeFirst(2) }
        else if path.hasPrefix("/") { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".caboose-upload-") }) else { return nil }
        return path
    }

    public static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Active document formats are shared explicitly rather than loaded in a local web view.
    public static func canQuickLook(_ path: String) -> Bool {
        isImage(path) || ["pdf", "txt", "md", "csv", "json", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf"].contains((path as NSString).pathExtension.lowercased())
    }

    public static func proposedMessage(_ value: String) -> String? {
        guard value.count <= maximumComposeCharacters, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A sandboxed opaque-origin frame. Its CSP is first, before any agent markup.
    public static func htmlDocument(_ html: String) -> String {
        let inner = """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html{color-scheme:light dark}body{margin:12px;font:16px -apple-system,sans-serif;overflow-wrap:anywhere}*{box-sizing:border-box}svg,img,canvas{max-width:100%}</style>
        <script>
        for(const name of ['RTCPeerConnection','webkitRTCPeerConnection']){Object.defineProperty(window,name,{value:undefined,writable:false,configurable:false})}
        window.Caboose=Object.freeze({compose(message){if(navigator.userActivation.isActive&&typeof message==='string'&&message.length<=32000)parent.postMessage({caboose:'compose',message},'*')}});
        addEventListener('DOMContentLoaded',()=>{let last=0;const size=()=>{const height=Math.min(20000,Math.max(100,document.body?.scrollHeight||0,(document.body?.getBoundingClientRect().height||0)+24));if(height!==last){last=height;parent.postMessage({caboose:'size',height},'*')}};new ResizeObserver(size).observe(document.body);size()});
        </script>
        """ + html
        let escaped = inner.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src about:; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"><style>html,body{margin:0;padding:0;background:transparent}iframe{display:block;width:100%;border:0}</style></head><body>
        <iframe title="Interactive chart or tool" sandbox="allow-scripts" srcdoc="\(escaped)"></iframe>
        <script>const frame=document.querySelector('iframe');addEventListener('message',event=>{if(event.source!==frame.contentWindow)return;const d=event.data;if(d?.caboose==='size'&&Number.isFinite(d.height)){const height=Math.min(20000,Math.max(100,d.height));frame.style.height=height+'px';window.webkit.messageHandlers.artifact.postMessage({kind:'size',height})}if(d?.caboose==='compose'&&navigator.userActivation.isActive&&typeof d.message==='string'&&d.message.length<=32000)window.webkit.messageHandlers.artifact.postMessage({kind:'compose',message:d.message})});</script>
        </body></html>
        """
    }
}
