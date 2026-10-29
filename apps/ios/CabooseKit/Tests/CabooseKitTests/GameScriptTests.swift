#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import Testing
@testable import CabooseKit

/// Runs the game page's user scripts in JavaScriptCore, with the few browser globals they use
/// stood in for: timers run when the test drains them, and posts to the app are recorded.
final class GamePage {
    let context = JSContext()!
    private(set) var exceptions: [String] = []

    static let environment = #"""
    globalThis.window = globalThis;
    const tasks = [];
    // What a timer threw, which a browser reports as uncaught.
    globalThis.thrown = [];
    globalThis.setTimeout = (body) => { tasks.push(body); return tasks.length; };
    globalThis.drain = () => {
      for (let ran = 0; tasks.length; ran++) {
        if (ran > 100000) throw new Error("the page never settles");
        try { tasks.shift()(); } catch (error) { thrown.push(String(error && error.message || error)); }
      }
    };
    globalThis.DOMException = class DOMException extends Error {
      constructor(message, name) { super(message); this.name = name; }
    };
    globalThis.structuredClone = function clone(value) {
      if (value instanceof Date) return new Date(value.getTime());
      if (ArrayBuffer.isView(value)) return value.slice();
      if (Array.isArray(value)) return value.map(clone);
      if (value && typeof value === "object") {
        const copy = {};
        for (const key of Object.keys(value)) copy[key] = clone(value[key]);
        return copy;
      }
      return value;
    };
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    globalThis.btoa = (binary) => {
      let out = "";
      for (let i = 0; i < binary.length; i += 3) {
        const a = binary.charCodeAt(i), b = binary.charCodeAt(i + 1), c = binary.charCodeAt(i + 2);
        const n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += alphabet[n >> 18] + alphabet[(n >> 12) & 63] + (isNaN(b) ? "=" : alphabet[(n >> 6) & 63]) + (isNaN(c) ? "=" : alphabet[n & 63]);
      }
      return out;
    };
    globalThis.atob = (text) => {
      let bits = 0, value = 0, out = "";
      for (const character of text.replace(/=+$/, "")) {
        value = (value << 6) | alphabet.indexOf(character);
        bits += 6;
        if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 255); }
      }
      return out;
    };
    globalThis.crossOriginIsolated = true;
    globalThis.posted = [];
    globalThis.webkit = { messageHandlers: { cabooseFS: { postMessage(body) {
      posted.push(JSON.parse(JSON.stringify(body)));
      return Promise.resolve();
    } } } };
    globalThis.indexedDB = { open(name) { return { webkit: name }; }, deleteDatabase(name) { return { webkit: name }; }, cmp() { return 0; } };
    const listeners = {};
    globalThis.addEventListener = (type, listener) => { (listeners[type] = listeners[type] || []).push(listener); };
    globalThis.dispatchEvent = (event) => { for (const listener of listeners[event.type] || []) listener(event); return true; };
    globalThis.Event = class Event { constructor(type) { this.type = type; } };
    globalThis.performance = { now: () => 1 };
    globalThis.nativePads = [];
    globalThis.navigator = { getGamepads() { return nativePads; } };
    """#

    init() {
        context.exceptionHandler = { [weak self] _, exception in
            self?.exceptions.append(exception?.toString() ?? "an exception")
        }
        run(Self.environment)
    }

    @discardableResult
    func run(_ script: String) -> JSValue? {
        let value = context.evaluateScript(script)
        context.evaluateScript("drain()")
        return value
    }

    func json(_ expression: String) -> Any? {
        guard let text = context.evaluateScript("JSON.stringify(\(expression))")?.toString() else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
}

@Suite struct GameFSScriptTests {
    /// What Emscripten's IDBFS does (library_idbfs.js): open with an upgrade that makes
    /// FILE_DATA and its timestamp index, list through the index's key cursor, read with get,
    /// write with put and delete in one read-write transaction.
    static let idbfs = #"""
    const order = [];
    const DB_STORE = "FILE_DATA";
    function getDB(name, callback) {
      const request = indexedDB.open(name, 21);
      request.onupgradeneeded = (event) => {
        order.push("upgrade " + event.oldVersion + "→" + event.newVersion);
        const db = event.target.result, transaction = event.target.transaction;
        const store = db.objectStoreNames.contains(DB_STORE) ? transaction.objectStore(DB_STORE) : db.createObjectStore(DB_STORE);
        if (!store.indexNames.contains("timestamp")) store.createIndex("timestamp", "timestamp", { unique: false });
      };
      request.onsuccess = () => { order.push("open"); callback(null, request.result); };
      request.onerror = (event) => { callback(event.target.error); event.preventDefault(); };
    }
    function getRemoteSet(db, callback) {
      const entries = {};
      const transaction = db.transaction([DB_STORE], "readonly");
      transaction.onerror = (event) => { callback(event.target.error); event.preventDefault(); };
      transaction.objectStore(DB_STORE).index("timestamp").openKeyCursor().onsuccess = (event) => {
        const cursor = event.target.result;
        if (!cursor) { order.push("listed"); return callback(null, entries); }
        entries[cursor.primaryKey] = { timestamp: cursor.key };
        cursor.continue();
      };
    }
    """#

    func page(_ seed: GameSeed) -> GamePage {
        let page = GamePage()
        page.run(GameFSScript.source(seed: seed))
        page.run(Self.idbfs)
        return page
    }

    var seed: GameSeed {
        var seed = GameSeed(mounts: ["/powder"])
        seed.entries["/powder"] = ["/powder/powder.pref": .file(mtime: 5000, data: Data([1, 2, 3])), "/powder/Saves": .directory(mtime: 4000)]
        return seed
    }

    @Test func idbfsReadsTheSeed() throws {
        let page = page(seed)
        page.run("""
        var listed, read;
        getDB("/powder", (error, db) => getRemoteSet(db, (error, entries) => {
          listed = Object.keys(entries).sort().map((key) => [key, entries[key].timestamp instanceof Date, entries[key].timestamp.getTime()]);
          const request = db.transaction([DB_STORE], "readwrite").objectStore(DB_STORE).get("/powder/powder.pref");
          request.onsuccess = (event) => {
            const entry = event.target.result;
            read = { mode: entry.mode, contents: Array.from(entry.contents), timestamp: entry.timestamp.getTime() };
          };
        }));
        """)
        #expect(page.exceptions.isEmpty, "\(page.exceptions)")
        #expect(page.json("order") as? [String] == ["upgrade 0→21", "open", "listed"])
        let listed = try #require(page.json("listed") as? [[Any]])
        #expect(listed.map { $0[0] as? String } == ["/powder/Saves", "/powder/powder.pref"])
        #expect(listed.allSatisfy { $0[1] as? Bool == true })
        #expect(listed.map { $0[2] as? Double } == [4000, 5000])
        let read = try #require(page.json("read") as? [String: Any])
        #expect(read["contents"] as? [Int] == [1, 2, 3] && read["timestamp"] as? Double == 5000)
        #expect((read["mode"] as? Int).map { $0 & 0o170000 } == 0o100000)
        // Reading changed nothing, so nothing went to the app.
        #expect((page.json("posted") as? [Any])?.isEmpty == true)
    }

    @Test func writesReachTheAppWhenTheirTransactionCompletes() throws {
        let page = page(seed)
        page.run("""
        getDB("/powder", (error, db) => {
          const transaction = db.transaction([DB_STORE], "readwrite");
          const store = transaction.objectStore(DB_STORE);
          transaction.oncomplete = () => order.push("complete");
          store.put({ timestamp: new Date(9000), mode: 0o100664, contents: new Uint8Array([9, 8]) }, "/powder/Saves/a.cps").onsuccess =
            () => order.push("put");
          store.put({ timestamp: new Date(9000), mode: 0o40775 }, "/powder/Stamps").onsuccess = () => order.push("mkdir");
          store.delete("/powder/powder.pref").onsuccess = () => order.push("delete");
          order.push("queued");
        });
        """)
        #expect(page.exceptions.isEmpty, "\(page.exceptions)")
        #expect(page.json("order") as? [String] == ["upgrade 0→21", "open", "queued", "put", "mkdir", "delete", "complete"])
        let posted = try #require(page.json("posted") as? [[String: Any]])
        #expect(posted.count == 1)
        #expect(posted.first?["type"] as? String == "changes" && posted.first?["mount"] as? String == "/powder")
        let changes = try #require(posted.first?["changes"] as? [[String: String]])
        #expect(changes == [["path": "/powder/Saves/a.cps", "kind": "file", "data": Data([9, 8]).base64EncodedString()],
                            ["path": "/powder/Stamps", "kind": "directory"],
                            ["path": "/powder/powder.pref", "kind": "removed"]])
        // The app reads them back as the planner's changes.
        #expect(GameSaveSync.changes(posted.first?["changes"] as? [[String: Any]] ?? [], mount: "/powder") == [
            GameSaveChange(path: "/powder/Saves/a.cps", kind: .file(Data([9, 8]))),
            GameSaveChange(path: "/powder/Stamps", kind: .directory),
            GameSaveChange(path: "/powder/powder.pref", kind: .removed),
        ])
    }

    @Test func aReopenedDatabaseKeepsWhatWasWritten() throws {
        let page = page(GameSeed(mounts: ["/powder"]))
        page.run("""
        var after;
        getDB("/powder", (error, db) => {
          const transaction = db.transaction([DB_STORE], "readwrite");
          transaction.objectStore(DB_STORE).put({ timestamp: new Date(1), mode: 0o100664, contents: new Uint8Array([1]) }, "/powder/x");
          transaction.oncomplete = () => getRemoteSet(db, (error, entries) => { after = Object.keys(entries); });
        });
        """)
        #expect(page.exceptions.isEmpty, "\(page.exceptions)")
        #expect(page.json("after") as? [String] == ["/powder/x"])
    }

    @Test func otherDatabasesAreWebKits() {
        let page = page(seed)
        #expect(page.json("indexedDB.open('/elsewhere', 1)") as? [String: String] == ["webkit": "/elsewhere"])
        #expect(page.json("indexedDB.deleteDatabase('/elsewhere')") as? [String: String] == ["webkit": "/elsewhere"])
        #expect(page.json("window.cabooseFS.mounts") as? [String] == ["/powder"])
    }

    @Test func readOnlyTransactionsRefuseWritesAndUnknownStoresAreNotFound() {
        let page = page(seed)
        page.run("""
        var errors = [];
        getDB("/powder", (error, db) => {
          try { db.transaction([DB_STORE], "readonly").objectStore(DB_STORE).put({}, "/powder/y"); } catch (e) { errors.push(e.name); }
          try { db.transaction(["OTHER"], "readonly"); } catch (e) { errors.push(e.name); }
          try { db.createObjectStore("LATE"); } catch (e) { errors.push(e.name); }
          const transaction = db.transaction([DB_STORE], "readonly");
          transaction.oncomplete = () => {
            try { transaction.objectStore(DB_STORE).get("/powder/powder.pref"); } catch (e) { errors.push(e.name); }
          };
        });
        """)
        #expect(page.json("errors") as? [String] == ["ReadOnlyError", "NotFoundError", "InvalidStateError", "TransactionInactiveError"])
    }

    @Test func aSuccessHandlerThatThrowsAbortsItsTransaction() {
        let page = page(seed)
        page.run("""
        var outcome = [];
        getDB("/powder", (error, db) => {
          const transaction = db.transaction([DB_STORE], "readwrite");
          transaction.onabort = (event) => outcome.push("abort " + event.target.error.name);
          transaction.oncomplete = () => outcome.push("complete");
          const store = transaction.objectStore(DB_STORE);
          store.delete("/powder/powder.pref").onsuccess = () => { throw new Error("game bug"); };
        });
        """)
        #expect(page.json("outcome") as? [String] == ["abort AbortError"])
        // Undone: the save is still there and nothing went to the app.
        #expect((page.json("posted") as? [Any])?.isEmpty == true)
        #expect(page.json("thrown") as? [String] == ["game bug"]) // still the page's error
    }

    @Test func aPageThatIsNotIsolatedSaysWhyItStopped() throws {
        let page = GamePage()
        page.run("crossOriginIsolated = false;")
        page.run(GameFSScript.source(seed: seed))
        page.run("dispatchEvent(Object.assign(new Event('error'), { message: 'SharedArrayBuffer is not defined' }));")
        page.run("dispatchEvent(Object.assign(new Event('error'), { message: 'later' }));")
        let posted = try #require(page.json("posted") as? [[String: String]])
        #expect(posted == [["type": "isolation", "message": "SharedArrayBuffer is not defined"]])
    }
}

@Suite struct GameGamepadScriptTests {
    func page() -> GamePage {
        let page = GamePage()
        page.run("var events = []; addEventListener('gamepadconnected', (e) => events.push(['connected', e.gamepad.index])); "
            + "addEventListener('gamepaddisconnected', (e) => events.push(['disconnected', e.gamepad.index, e.gamepad.connected]));")
        page.run(GameGamepadScript.source)
        return page
    }

    @Test func theOnScreenControllerIsAStandardGamepad() throws {
        let page = page()
        #expect(page.json("navigator.getGamepads()") as? [Any] != nil)
        #expect((page.json("navigator.getGamepads()") as? [Any])?.isEmpty == true)
        var state = GameGamepadState()
        state[.south] = 1
        state[.leftX] = 0.5
        let call = GameGamepadScript.call(state)
        page.context.setObject(call.arguments["buttons"], forKeyedSubscript: "buttons" as NSString)
        page.context.setObject(call.arguments["axes"], forKeyedSubscript: "axes" as NSString)
        page.run(call.body)
        #expect(page.exceptions.isEmpty, "\(page.exceptions)")
        let pad = try #require((page.json("navigator.getGamepads()") as? [[String: Any]])?.first)
        #expect(pad["mapping"] as? String == "standard" && pad["connected"] as? Bool == true && pad["index"] as? Int == 0)
        #expect(pad["axes"] as? [Double] == [0.5, 0, 0, 0])
        let buttons = try #require(pad["buttons"] as? [[String: Any]])
        #expect(buttons.count == 17)
        #expect(buttons[0]["pressed"] as? Bool == true && buttons[0]["value"] as? Double == 1 && buttons[1]["pressed"] as? Bool == false)
        #expect(page.json("events") as? [[AnyHashable]] == [["connected", 0]])
    }

    @Test func aHardwareControllerKeepsItsIndex() throws {
        let page = page()
        page.run("cabooseGamepad.update([1], [0, 0, 0, 0]);")
        page.run("nativePads = [{ index: 0, id: 'pad', mapping: 'standard' }];")
        let ids = page.json("navigator.getGamepads().map((pad) => pad && pad.id)") as? [String]
        #expect(ids == ["pad", "Caboose on-screen controller (STANDARD GAMEPAD)"])
        page.run("cabooseGamepad.update([0], [0, 0, 0, 0]); cabooseGamepad.disconnect(); cabooseGamepad.disconnect();")
        #expect(page.json("events") as? [[AnyHashable]] == [["connected", 0], ["disconnected", 0, false], ["connected", 1],
                                                            ["disconnected", 1, false]])
        #expect((page.json("navigator.getGamepads()") as? [Any])?.count == 1)
    }
}
#endif
