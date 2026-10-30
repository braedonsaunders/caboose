// caboose-app: window.caboose, the native API of an agent app's top frame. Each call is a
// window message to the relay in the runtime's own script world (world.js); calls for a
// capability the app's manifest does not declare are refused by the runtime.
(() => {
  const app = Object.freeze(__CABOOSE_APP__)
  // The app's network origin (net.py on the computer, AgentAppNet on a device), or null.
  const netBase = __CABOOSE_NET__
  const pending = new Map()
  const processes = new Map()
  let next = 1

  function call(method, params = {}) {
    const id = next++
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject })
      window.postMessage({ caboose: 'request', id, method, params }, '*')
    })
  }

  window.addEventListener('message', event => {
    if (event.source !== window) return
    const data = event.data
    if (!data || typeof data !== 'object') return
    if (data.caboose === 'reply') {
      const waiting = pending.get(data.id)
      if (!waiting) return
      pending.delete(data.id)
      if (data.ok) waiting.resolve(data.value)
      else waiting.reject(new Error(data.error ?? 'The request failed'))
      event.stopImmediatePropagation()
    } else if (data.caboose === 'event') {
      const process = processes.get(data.key)
      if (!process) return
      if (data.type === 'exit') {
        processes.delete(data.key)
        process.exit({ code: data.code, signal: data.signal })
      } else {
        process.output(data.type, data.data)
      }
      event.stopImmediatePropagation()
    }
  })

  const base64 = {
    encode(bytes) {
      const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
      let text = ''
      for (let i = 0; i < view.length; i += 0x8000) text += String.fromCharCode(...view.subarray(i, i + 0x8000))
      return btoa(text)
    },
    decode(text) {
      const raw = atob(text)
      const bytes = new Uint8Array(raw.length)
      for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
      return bytes
    },
  }

  /** Starts a program and streams its output. Resolves once it is running. */
  async function spawn(argv, options = {}) {
    const { onStdout, onStderr, onExit, ...rest } = options
    const key = `${Date.now().toString(36)}-${next++}`
    let exited
    const done = new Promise(resolve => { exited = resolve })
    processes.set(key, {
      output(type, data) {
        const listener = type === 'stderr' ? onStderr : onStdout
        if (listener) listener(data)
      },
      exit(status) {
        if (onExit) onExit(status)
        exited(status)
      },
    })
    try {
      const { pid } = await call('spawn', { argv, key, ...rest })
      return Object.freeze({
        pid,
        exited: done,
        write: text => call('process.write', { key, data: String(text) }),
        closeStdin: () => call('process.closeStdin', { key }),
        kill: (signal = 'TERM') => call('process.kill', { key, signal }),
      })
    } catch (error) {
      processes.delete(key)
      throw error
    }
  }

  const files = Object.freeze({
    readText: path => call('files.read', { path }).then(data => new TextDecoder().decode(base64.decode(data))),
    readBytes: path => call('files.read', { path }).then(base64.decode),
    readJSON: path => files.readText(path).then(JSON.parse),
    writeText: (path, text) => call('files.write', { path, data: base64.encode(new TextEncoder().encode(String(text))) }),
    writeBytes: (path, bytes) => call('files.write', { path, data: base64.encode(bytes) }),
    writeJSON: (path, value) => files.writeText(path, JSON.stringify(value, null, 2)),
    list: (path = '.') => call('files.list', { path }),
    stat: path => call('files.stat', { path }),
    exists: path => call('files.stat', { path }).then(() => true, () => false),
    mkdir: path => call('files.mkdir', { path }),
    remove: (path, options = {}) => call('files.remove', { path, recursive: options.recursive === true }),
  })

  // Names a page's script may not set on a request; caboose.fetch sends them under
  // X-Caboose-Header-<name>, which the network origin renames.
  const reserved = /^(accept-charset|accept-encoding|connection|content-length|cookie2?|date|dnt|expect|host|keep-alive|origin|referer|te|trailer|transfer-encoding|upgrade|user-agent|via|proxy-.*|sec-.*)$/i

  /** The URL of any http or https resource through the app's network origin. */
  function netURL(target) {
    if (netBase === null) {
      throw new Error('This app does not declare the "net" capability in app.json; add it and start the app again')
    }
    const url = new URL(String(target), location.href)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new TypeError('caboose.net reaches http and https URLs')
    if (url.username || url.password) throw new TypeError('Send credentials in a header, not in the URL')
    return `${netBase}${url.protocol.slice(0, -1)}/${encodeURIComponent(url.host)}${url.pathname}${url.search}`
  }

  /** fetch, for any http or https URL: no CORS, any headers, streamed. */
  async function netFetch(input, init = {}) {
    const request = input instanceof Request ? input : null
    const headers = new Headers()
    for (const [name, value] of new Headers(init.headers ?? request?.headers ?? {})) {
      headers.append(reserved.test(name) ? `X-Caboose-Header-${name}` : name, value)
    }
    let body = init.body
    if (body === undefined && request && request.method !== 'GET' && request.method !== 'HEAD') body = await request.arrayBuffer()
    return fetch(netURL(request ? request.url : input), {
      method: init.method ?? request?.method ?? 'GET',
      headers,
      body,
      signal: init.signal ?? request?.signal,
      cache: init.cache ?? 'no-store',
      credentials: 'omit',
      redirect: 'follow',
      referrerPolicy: 'no-referrer',
    })
  }

  const net = Object.freeze({ url: netURL, fetch: netFetch })

  Object.defineProperty(window, 'caboose', {
    value: Object.freeze({
      app,
      exec: (argv, options = {}) => call('exec', { argv, ...options }),
      spawn,
      files,
      notify: (title, body = '') => call('notify', typeof title === 'object' ? title : { title, body }),
      open: target => call('open', { target }),
      fetch: netFetch,
      net,
    }),
  })
})()
