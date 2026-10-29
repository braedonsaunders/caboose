import Foundation

/// A game's saves as the page starts with them: for each save mount, the entries IDBFS keeps,
/// keyed by absolute path in the game's file system (the mount itself is not an entry).
struct GameSeed: Equatable {
    enum Entry: Equatable {
        case directory(mtime: Double)
        case file(mtime: Double, data: Data)
    }

    var mounts: [String]
    var entries: [String: [String: Entry]] = [:]

    /// `{ mounts: [...], entries: { mount: { path: { mtime, dir? , data? (base64) } } } }`.
    func json() -> String {
        var databases: [String: Any] = [:]
        for mount in mounts {
            var items: [String: Any] = [:]
            for (path, entry) in entries[mount] ?? [:] {
                switch entry {
                case .directory(let mtime): items[path] = ["mtime": mtime, "dir": true]
                case .file(let mtime, let data): items[path] = ["mtime": mtime, "data": data.base64EncodedString()]
                }
            }
            databases[mount] = items
        }
        let object: [String: Any] = ["mounts": mounts, "entries": databases]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The user script a game page starts with (docs/game-handoff.md, "Saves").
///
/// It defines `window.cabooseFS` and puts an IndexedDB in front of WebKit's that answers the
/// databases named after the save mounts (IDBFS names each database after its mount point)
/// from the seed, and passes every other database to WebKit. The save databases implement
/// what Emscripten's IDBFS uses: `open` with `onupgradeneeded`, one object store with a
/// `timestamp` index and its key cursor, `get`, `put` and `delete`, and transactions whose
/// callbacks fire asynchronously in IndexedDB's order, `oncomplete` after every request's.
/// When a read-write transaction that changed something completes, its changes go to the
/// app through the `cabooseFS` message handler. A page that is not cross-origin isolated,
/// which threaded WebAssembly needs, reports the first error it stops on, so the app can
/// decline the game.
enum GameFSScript {
    static let handlerName = "cabooseFS"

    static func source(seed: GameSeed) -> String {
        "(\(shim))(\(seed.json()));"
    }

    static let shim = #"""
    function (seed) {
      "use strict";
      const DIR = 0o40775, FILE = 0o100664, TYPE = 0o170000, ISDIR = 0o40000;
      const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cabooseFS;
      const post = (body) => { if (native) native.postMessage(body).catch(() => {}); };
      const mounts = new Set(seed.mounts);

      const fromBase64 = (text) => {
        const binary = atob(text), bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
      };
      const toBase64 = (value) => {
        const bytes = ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : new Uint8Array(value);
        let binary = "";
        for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return btoa(binary);
      };
      const later = (body) => setTimeout(body, 0);
      const domError = (name, message) => new DOMException(message, name);
      const event = (target, type, extra) => Object.assign({ type, target, currentTarget: target, defaultPrevented: false,
        preventDefault() { this.defaultPrevented = true; }, stopPropagation() {} }, extra);
      const stringList = (names) => {
        const list = Array.from(names).sort();
        list.contains = (name) => list.includes(name);
        list.item = (index) => (index < list.length ? list[index] : null);
        return list;
      };
      // IndexedDB key order: numbers, then dates, then strings.
      const rank = (key) => (typeof key === "number" ? 0 : key instanceof Date ? 1 : 2);
      const compare = (a, b) => {
        if (rank(a) !== rank(b)) return rank(a) - rank(b);
        const x = a instanceof Date ? a.getTime() : a, y = b instanceof Date ? b.getTime() : b;
        return x < y ? -1 : x > y ? 1 : 0;
      };

      class Request {
        constructor(source, transaction) {
          Object.assign(this, { source, transaction, result: undefined, error: null, readyState: "pending",
            onsuccess: null, onerror: null, onupgradeneeded: null, onblocked: null });
        }
        _succeed(result) {
          this.result = result;
          this.readyState = "done";
          if (this.onsuccess) this.onsuccess(event(this, "success"));
        }
        _fail(error) {
          this.error = error;
          this.readyState = "done";
          const failure = event(this, "error");
          if (this.onerror) this.onerror(failure);
          return failure;
        }
      }

      class Transaction {
        constructor(db, names, mode) {
          Object.assign(this, { db, mode, objectStoreNames: stringList(names), error: null,
            onerror: null, onabort: null, oncomplete: null });
          this._queue = [];
          this._undo = new Map();
          this._finished = false;
          this._scheduled = false;
          this._schedule();
        }
        objectStore(name) {
          if (!this.db._stores.has(name)) throw domError("NotFoundError", "No object store named " + name);
          return new ObjectStore(this, name);
        }
        abort(error) {
          if (this._finished) throw domError("InvalidStateError", "The transaction has finished");
          this.error = error || null;
          for (const [store, saved] of this._undo) {
            for (const [key, value] of saved) value === undefined ? store.data.delete(key) : store.data.set(key, value);
          }
          this._finished = true;
          this._queue = [];
          later(() => { if (this.onabort) this.onabort(event(this, "abort")); });
        }
        _request(source, operation, request) {
          if (this._finished) throw domError("TransactionInactiveError", "The transaction has finished");
          request = request || new Request(source, this);
          this._queue.push(() => {
            let result;
            try { result = operation(); } catch (error) {
              const failure = request._fail(error);
              if (this.onerror) this.onerror(failure);
              // As in IndexedDB, an error nobody prevented aborts its transaction.
              if (!failure.defaultPrevented && !this._finished) this.abort(error);
              return;
            }
            try { request._succeed(result); } catch (error) {
              // As in IndexedDB, a success handler that throws aborts its transaction.
              if (!this._finished) this.abort(domError("AbortError", "A success handler threw"));
              later(() => { throw error; });
            }
          });
          this._schedule();
          return request;
        }
        _writable() {
          if (this.mode === "readonly") throw domError("ReadOnlyError", "The transaction is read-only");
        }
        _remember(store, key) {
          if (!this._undo.has(store)) this._undo.set(store, new Map());
          const saved = this._undo.get(store);
          if (!saved.has(key)) saved.set(key, store.data.get(key));
        }
        _schedule() {
          if (this._scheduled || this._finished) return;
          this._scheduled = true;
          later(() => this._run());
        }
        _run() {
          this._scheduled = false;
          // Requests made by a request's callback join the queue and run in this same pass.
          while (this._queue.length && !this._finished) this._queue.shift()();
          if (this._finished) return;
          this._finished = true;
          if (this.mode === "readwrite") this.db._report(this._undo);
          if (this.oncomplete) this.oncomplete(event(this, "complete"));
          if (this._done) this._done();
        }
      }

      class ObjectStore {
        constructor(transaction, name) {
          this.transaction = transaction;
          this.name = name;
          this._store = transaction.db._stores.get(name);
        }
        get keyPath() { return null; }
        get autoIncrement() { return false; }
        get indexNames() { return stringList(this._store.indexes.keys()); }
        createIndex(name, keyPath) {
          if (this.transaction.mode !== "versionchange") throw domError("InvalidStateError", "Indexes are made while upgrading");
          if (this._store.indexes.has(name)) throw domError("ConstraintError", "An index named " + name + " exists");
          this._store.indexes.set(name, keyPath);
          return new Index(this, name);
        }
        index(name) {
          if (!this._store.indexes.has(name)) throw domError("NotFoundError", "No index named " + name);
          return new Index(this, name);
        }
        get(key) {
          return this.transaction._request(this, () => {
            const value = this._store.data.get(key);
            return value === undefined ? undefined : structuredClone(value);
          });
        }
        put(value, key) {
          this.transaction._writable();
          if (key === undefined) throw domError("DataError", "A key is required");
          const copy = structuredClone(value);
          return this.transaction._request(this, () => {
            this.transaction._remember(this._store, key);
            this._store.data.set(key, copy);
            return key;
          });
        }
        delete(key) {
          this.transaction._writable();
          return this.transaction._request(this, () => {
            this.transaction._remember(this._store, key);
            this._store.data.delete(key);
            return undefined;
          });
        }
      }

      class Index {
        constructor(objectStore, name) {
          this.objectStore = objectStore;
          this.name = name;
          this.keyPath = objectStore._store.indexes.get(name);
        }
        openKeyCursor() {
          const store = this.objectStore, keyPath = this.keyPath;
          const rows = [];
          for (const [primaryKey, value] of store._store.data) {
            if (value && value[keyPath] !== undefined) rows.push({ primaryKey, key: value[keyPath] });
          }
          rows.sort((a, b) => compare(a.key, b.key) || compare(a.primaryKey, b.primaryKey));
          let position = 0, request;
          const step = () => {
            if (position >= rows.length) return null;
            const row = rows[position++];
            return { source: this, direction: "next", primaryKey: row.primaryKey, key: structuredClone(row.key),
              continue: () => {
                request.readyState = "pending";
                store.transaction._request(this, step, request);
              } };
          };
          request = store.transaction._request(this, step);
          return request;
        }
      }

      class Database {
        constructor(name, entries) {
          Object.assign(this, { name, version: 0, onversionchange: null, onclose: null, onabort: null, onerror: null });
          this._stores = new Map();
          this._entries = entries;
          this._upgrade = null;
        }
        get objectStoreNames() { return stringList(this._stores.keys()); }
        createObjectStore(name) {
          if (!this._upgrade) throw domError("InvalidStateError", "Object stores are made while upgrading");
          if (this._stores.has(name)) throw domError("ConstraintError", "An object store named " + name + " exists");
          // The first store holds the save; IDBFS makes only one.
          this._stores.set(name, { data: this._entries || new Map(), indexes: new Map() });
          this._entries = null;
          return new ObjectStore(this._upgrade, name);
        }
        transaction(names, mode) {
          names = typeof names === "string" ? [names] : Array.from(names);
          for (const name of names) {
            if (!this._stores.has(name)) throw domError("NotFoundError", "No object store named " + name);
          }
          return new Transaction(this, names, mode === "readwrite" ? "readwrite" : "readonly");
        }
        close() {}
        // The keys a completed read-write transaction changed, as they are now.
        _report(undo) {
          const changes = [];
          for (const [store, saved] of undo) {
            for (const key of saved.keys()) {
              if (typeof key !== "string") continue;
              const value = store.data.get(key);
              if (value === undefined) changes.push({ path: key, kind: "removed" });
              else if (((value.mode || 0) & TYPE) === ISDIR) changes.push({ path: key, kind: "directory" });
              else if (value.contents !== undefined) changes.push({ path: key, kind: "file", data: toBase64(value.contents) });
            }
          }
          if (changes.length) post({ type: "changes", mount: this.name, changes });
        }
      }

      const seeded = (mount) => {
        const entries = new Map(), items = (seed.entries && seed.entries[mount]) || {};
        for (const path of Object.keys(items)) {
          const item = items[path], timestamp = new Date(item.mtime);
          entries.set(path, item.dir ? { timestamp, mode: DIR } : { timestamp, mode: FILE, contents: fromBase64(item.data || "") });
        }
        return entries;
      };
      const databases = new Map();

      const open = (name, version) => {
        const request = new Request(null, null);
        later(() => {
          let db = databases.get(name);
          if (!db) {
            db = new Database(name, seeded(name));
            databases.set(name, db);
          }
          const wanted = version === undefined ? Math.max(db.version, 1) : Number(version);
          if (!(wanted >= 1)) return request._fail(new TypeError("The version must be at least 1"));
          if (wanted < db.version) return request._fail(domError("VersionError", "The database is at version " + db.version));
          request.result = db;
          if (wanted === db.version) return request._succeed(db);
          const oldVersion = db.version;
          db.version = wanted;
          const upgrade = new Transaction(db, db._stores.keys(), "versionchange");
          db._upgrade = upgrade;
          upgrade._done = () => {
            db._upgrade = null;
            request.transaction = null;
            request._succeed(db);
          };
          request.transaction = upgrade;
          request.readyState = "done";
          if (request.onupgradeneeded) request.onupgradeneeded(event(request, "upgradeneeded", { oldVersion, newVersion: wanted }));
        });
        return request;
      };

      const real = window.indexedDB;
      const shim = {
        open(name, version) {
          return mounts.has(String(name)) ? open(String(name), version) : real.open.apply(real, arguments);
        },
        // Deleting a save database forgets it for this page; the computer keeps its copy.
        deleteDatabase(name) {
          if (!mounts.has(String(name))) return real.deleteDatabase.apply(real, arguments);
          const request = new Request(null, null);
          databases.delete(String(name));
          later(() => request._succeed(undefined));
          return request;
        },
        cmp(a, b) { return real.cmp(a, b); },
        databases() { return real.databases ? real.databases() : Promise.resolve([]); },
      };
      try {
        Object.defineProperty(window, "indexedDB", { configurable: true, enumerable: true, get: () => shim });
      } catch (error) {
        post({ type: "failure", message: "The game's saves could not be connected: " + error.message });
      }
      Object.defineProperty(window, "cabooseFS", { value: Object.freeze({ mounts: Array.from(mounts) }) });

      // Without cross-origin isolation there is no SharedArrayBuffer, which threaded WebAssembly
      // needs: when the page then stops on an error, the app declines the game.
      if (!window.crossOriginIsolated) {
        let reported = false;
        const stopped = (message) => {
          if (reported) return;
          reported = true;
          post({ type: "isolation", message: String(message || "") });
        };
        window.addEventListener("error", (event) => stopped(event.message));
        window.addEventListener("unhandledrejection", (event) => stopped(event.reason && event.reason.message || event.reason));
      }
    }
    """#
}
