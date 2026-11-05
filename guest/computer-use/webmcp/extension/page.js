// Caboose WebMCP, page side (the page's own JavaScript world, from document_start).
// It lists and runs the tools the page declares through WebMCP (document.modelContext: tools
// registered with registerTool, and <form toolname> declarative tools), and tools derived
// from the page's own semantics so that every page offers some: each form (fill it and
// submit), its links (follow one) and its buttons outside forms (press one). Chromium's
// native WebMCP answers when the browser has it; otherwise this file provides
// document.modelContext itself, so pages can register tools either way. Requests come from
// content.js through window messages tagged with a per-page channel.
(() => {
  if (window.__cabooseWebMCP) return
  window.__cabooseWebMCP = true

  // document.modelContext where the browser has none: the same registerTool/getTools/
  // executeTool surface Chromium's WebMCP offers.
  if (!document.modelContext) {
    const registered = new Map()
    const context = {
      registerTool(tool) {
        if (!tool || typeof tool.name !== 'string' || typeof tool.execute !== 'function') throw new TypeError('a tool needs a name and execute')
        registered.set(tool.name, tool)
      },
      unregisterTool(name) { registered.delete(typeof name === 'string' ? name : name?.name) },
      provideContext({ tools = [] } = {}) { registered.clear(); for (const tool of tools) context.registerTool(tool) },
      clearContext() { registered.clear() },
      async getTools() { return [...registered.values()].map(t => ({ name: t.name, description: t.description ?? '', inputSchema: t.inputSchema ?? { type: 'object', properties: {} } })) },
      async executeTool(tool, input) {
        const found = registered.get(typeof tool === 'string' ? tool : tool?.name)
        if (!found) throw new Error('no such tool')
        return found.execute(input ?? {}, { requestUserInteraction: async callback => callback() })
      },
    }
    Object.defineProperty(document, 'modelContext', { value: context, configurable: true })
  }

  const visible = element => {
    if (!element.isConnected) return false
    const box = element.getBoundingClientRect()
    if (box.width === 0 && box.height === 0) return false
    const style = getComputedStyle(element)
    return style.visibility !== 'hidden' && style.display !== 'none'
  }
  const clean = text => (text ?? '').replace(/\s+/g, ' ').trim()
  const slug = text => clean(text).toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 40)
  const labelOf = field => {
    const byFor = field.id && document.querySelector(`label[for="${CSS.escape(field.id)}"]`)
    return clean(field.getAttribute('aria-label') || byFor?.textContent || field.closest('label')?.textContent
      || field.getAttribute('placeholder') || field.getAttribute('title') || field.name || field.id)
  }
  const nameOf = element => clean(element.getAttribute('aria-label') || element.textContent || element.value || element.title)
  const setValue = (field, value) => {
    const proto = field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : field instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(field, value)
    field.dispatchEvent(new Event('input', { bubbles: true }))
    field.dispatchEvent(new Event('change', { bubbles: true }))
  }

  // One tool per form the page does not already declare: its fields are the parameters.
  function formTools() {
    const tools = []
    const used = new Set()
    for (const [index, form] of [...document.forms].entries()) {
      if (form.hasAttribute('toolname') || !visible(form)) continue
      const params = {}, fill = []
      const radios = new Map()
      for (const field of form.elements) {
        if (!visible(field) || field.disabled) continue
        const type = (field.type || '').toLowerCase()
        if (['submit', 'button', 'reset', 'image', 'hidden', 'file'].includes(type) || field instanceof HTMLButtonElement || field instanceof HTMLFieldSetElement) continue
        if (type === 'radio') {
          const group = radios.get(field.name) ?? { label: clean(field.closest('fieldset')?.querySelector('legend')?.textContent) || field.name, options: [] }
          group.options.push(field); radios.set(field.name, group); continue
        }
        const label = labelOf(field)
        let key = slug(label) || `field_${fill.length + 1}`
        while (params[key]) key += '_'
        if (type === 'checkbox') params[key] = { type: 'boolean', title: label }
        else if (field instanceof HTMLSelectElement) params[key] = { type: 'string', title: label, enum: [...field.options].map(o => clean(o.textContent)) }
        else params[key] = { type: type === 'number' || type === 'range' ? 'number' : 'string', title: label }
        fill.push({ key, field, type })
      }
      for (const [name, group] of radios) {
        let key = slug(group.label) || slug(name) || `choice_${fill.length + 1}`
        while (params[key]) key += '_'
        params[key] = { type: 'string', title: group.label, enum: group.options.map(o => labelOf(o)) }
        fill.push({ key, radios: group.options })
      }
      const submit = [...form.querySelectorAll('button:not([type]), button[type=submit], input[type=submit]')].find(visible)
      const action = submit ? nameOf(submit) : 'submit'
      let name = `form_${slug(form.getAttribute('aria-label') || form.querySelector('legend, h1, h2, h3')?.textContent || action) || index + 1}`
      while (used.has(name)) name += '_'
      used.add(name)
      tools.push({
        name, derived: true,
        description: `Fill this form (${Object.values(params).map(p => p.title).join(', ') || 'no fields'}) and press "${action}". Omitted fields keep their value; submit: false only fills it.`,
        inputSchema: { type: 'object', properties: { ...params, submit: { type: 'boolean' } } },
        async execute(input = {}) {
          const done = []
          for (const item of fill) {
            if (!(item.key in input)) continue
            const value = input[item.key]
            if (item.radios) {
              const option = item.radios.find(o => labelOf(o).toLowerCase() === String(value).toLowerCase())
              if (!option) throw new Error(`${item.key}: no option ${JSON.stringify(value)}`)
              option.click()
            } else if (item.type === 'checkbox') {
              if (item.field.checked !== Boolean(value)) item.field.click()
            } else if (item.field instanceof HTMLSelectElement) {
              const option = [...item.field.options].find(o => clean(o.textContent).toLowerCase() === String(value).toLowerCase() || o.value === String(value))
              if (!option) throw new Error(`${item.key}: no option ${JSON.stringify(value)}`)
              setValue(item.field, option.value)
            } else setValue(item.field, String(value))
            done.push(item.key)
          }
          if (input.submit !== false) {
            if (submit) submit.click(); else form.requestSubmit()
          }
          return { content: [{ type: 'text', text: `Filled ${done.length ? done.join(', ') : 'nothing'}${input.submit !== false ? ` and pressed "${action}"` : ''}.` }] }
        },
      })
    }
    return tools
  }

  // Follow a link, or press a button outside any form, by its text.
  function choiceTool(name, description, elements) {
    const named = new Map()
    for (const element of elements) {
      const text = nameOf(element)
      if (text && !named.has(text) && visible(element)) named.set(text, element)
      if (named.size >= 40) break
    }
    if (!named.size) return []
    const key = name === 'follow_link' ? 'link' : 'button'
    return [{
      name, derived: true, description,
      inputSchema: { type: 'object', properties: { [key]: { type: 'string', enum: [...named.keys()] } }, required: [key] },
      async execute(input = {}) {
        const element = named.get(input[key])
        if (!element) throw new Error(`no ${key} ${JSON.stringify(input[key])}`)
        element.click()
        return { content: [{ type: 'text', text: `Pressed "${input[key]}".` }] }
      },
    }]
  }

  async function declared() {
    try { return [...await document.modelContext.getTools()] } catch { return [] }
  }

  async function list() {
    const page = (await declared()).map(t => ({ name: t.name, description: t.description ?? '', inputSchema: t.inputSchema ?? {}, source: 'page' }))
    const derived = [...formTools(), ...choiceTool('follow_link', 'Follow a link of the page.', document.querySelectorAll('a[href]')),
      ...choiceTool('press_button', 'Press a button of the page that is outside its forms.', [...document.querySelectorAll('button, [role=button], input[type=button]')].filter(b => !b.form && !b.closest('form')))]
    return { title: document.title, url: location.href, tools: [...page, ...derived.filter(d => !page.some(p => p.name === d.name)).map(({ name, description, inputSchema }) => ({ name, description, inputSchema, source: 'derived' }))] }
  }

  async function call(name, input) {
    const tool = (await declared()).find(t => t.name === name)
    if (tool) {
      const result = await document.modelContext.executeTool(tool, input ?? {})
      return typeof result === 'string' ? safeParse(result) : result
    }
    const derived = [...formTools(), ...choiceTool('follow_link', '', document.querySelectorAll('a[href]')),
      ...choiceTool('press_button', '', [...document.querySelectorAll('button, [role=button], input[type=button]')].filter(b => !b.form && !b.closest('form')))]
    const own = derived.find(t => t.name === name)
    if (!own) throw new Error(`no tool ${name} on this page`)
    return own.execute(input ?? {})
  }
  const safeParse = text => { try { return JSON.parse(text) } catch { return { content: [{ type: 'text', text }] } } }

  window.addEventListener('message', async event => {
    const message = event.data
    if (event.source !== window || !message || message.cabooseWebMCP !== 'request') return
    let reply
    try {
      reply = { ok: true, result: message.op === 'tools' ? await list() : await call(message.name, message.args) }
    } catch (error) {
      reply = { ok: false, error: String(error?.message ?? error) }
    }
    window.postMessage({ cabooseWebMCP: 'reply', id: message.id, ...JSON.parse(JSON.stringify(reply)) }, '*')
  })
})()
