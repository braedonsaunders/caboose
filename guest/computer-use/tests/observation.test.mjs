import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Observer } from '../server/observation.mjs'

const win = (id, extra = {}) => ({ id, kind: 'toplevel', title: 'notes.txt - Mousepad', app_id: 'mousepad', parent: null, focused: true, ...extra })
const name = { id: '1-2-0.1-aaaaaa', role: 'text', name: 'Name', value: 'notes.txt', states: ['editable', 'showing'] }
const save = { id: '1-2-0.2-bbbbbb', role: 'button', name: 'Save', states: [] }

test('the first observation lists windows and controls under short ids', () => {
  const o = new Observer()
  const text = o.render({ windows: [win(7)], focused: 7 }, { elements: [name, save] })
  assert.equal(text, ['In toplevel 7 "notes.txt - Mousepad" (mousepad), focused',
    'e1 text "Name" = "notes.txt" [editable]', 'e2 button "Save"'].join('\n'))
  assert.equal(o.resolve('e2'), save.id)
  assert.equal(o.resolve(save.id), save.id)
})

test('later observations carry only the changes', () => {
  const o = new Observer()
  o.render({ windows: [win(7)], focused: 7 }, { elements: [name, save] })
  const dialog = { id: 9, kind: 'dialog', title: 'Save As', app_id: 'mousepad', parent: 7, focused: true }
  const text = o.render({ windows: [win(7, { focused: false }), dialog], focused: 9 }, { elements: [{ ...save, id: '9-2-0.2-bbbbbb' }] })
  assert.equal(text, ['Opened dialog 9 "Save As" (mousepad) of 7, focused', 'Focus is on dialog 9', 'e3 button "Save"'].join('\n'))
  const back = o.render({ windows: [win(7)], focused: 7 }, { elements: [{ ...name, value: 'cinder.txt' }] })
  assert.equal(back, ['Closed dialog 9 "Save As"', 'Focus is on toplevel 7', '~ e1 text "Name" = "cinder.txt" [editable]', '- e2'].join('\n'))
  assert.equal(o.render({ windows: [win(7)], focused: 7 }, { elements: [{ ...name, value: 'cinder.txt' }] }), 'No change.')
})

test('the first observation names the other windows only by count', () => {
  const o = new Observer()
  assert.match(o.render({ windows: [win(6, { focused: false }), win(7)], focused: 7 }, { elements: [save] }), /^In toplevel 7 .*, focused \(1 other window\)\ne1 button "Save"$/)
})

test('a window without an accessibility tree says so', () => {
  const o = new Observer()
  assert.match(o.render({ windows: [win(7)], focused: 7 }, { elements: [], note: 'No tree; use a screenshot.' }), /No tree; use a screenshot\.$/)
})
