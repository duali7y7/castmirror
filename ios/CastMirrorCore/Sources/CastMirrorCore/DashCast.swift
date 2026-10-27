import Foundation

/// DashCast is a public Cast receiver app (github.com/madmod/dashcast) that
/// opens any web page on the Chromecast. Pointing it at the CastMirror
/// receiver page avoids registering a Cast app ID. Same as
/// pc-sender/src/dashcast.js.
public enum DashCast {
    public static let appId = "84912283"
    public static let namespace = "urn:x-cast:com.madmod.dashcast"

    /// `force` navigates DashCast's whole page instead of loading the address
    /// in its iframe: the receiver page comes over plain http, which an iframe
    /// inside DashCast's https page would block as mixed content.
    public static func loadMessage(url: String) -> [String: Any] {
        ["url": url, "force": true, "reload": false, "reload_time": 0]
    }

    /// The receiver page address, carrying what the hello message would
    /// otherwise send over the Cast channel. `debugSeconds` shows the stats
    /// overlay for that long: 0 hides it, nil keeps it up.
    public static func receiverPageURL(base: String, webSocket: String, debugSeconds: Int?) -> String {
        guard var components = URLComponents(string: base) else { return base }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "ws", value: webSocket))
        if let debugSeconds { items.append(URLQueryItem(name: "debug", value: String(debugSeconds))) }
        components.queryItems = items
        return components.string ?? base
    }
}
