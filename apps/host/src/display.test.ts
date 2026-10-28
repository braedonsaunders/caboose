import { expect, it } from 'vitest'
import { parseEnvFile } from './display.js'

/** What caboose-display writes to /run/caboose/display.env: sh syntax, single-quoted values. */
export const DISPLAY_ENV = [
  "# written by caboose-display",
  "XDG_RUNTIME_DIR='/run/user/1000'",
  "WAYLAND_DISPLAY='wayland-caboose-0'",
  "DISPLAY=':110'",
  "XAUTHORITY='/run/user/1000/caboose-xauth'",
  "QT_QPA_PLATFORM='wayland;xcb'",
  "GDK_BACKEND='wayland,x11'",
].join('\n')

it('reads caboose-display\'s launch environment as sh would', () => {
  expect(parseEnvFile(DISPLAY_ENV)).toEqual([
    'XDG_RUNTIME_DIR=/run/user/1000', 'WAYLAND_DISPLAY=wayland-caboose-0', 'DISPLAY=:110',
    'XAUTHORITY=/run/user/1000/caboose-xauth', 'QT_QPA_PLATFORM=wayland;xcb', 'GDK_BACKEND=wayland,x11',
  ])
})

it('takes export, double quotes, escapes and comments, and skips what is not an assignment', () => {
  expect(parseEnvFile([
    'export GALLIUM_DRIVER=d3d12 # the WSL GPU',
    'A="it\'s \\"quoted\\""',
    "B='a b'c",
    'echo not-an-assignment',
    "C='unterminated",
    '',
  ].join('\n'))).toEqual(['GALLIUM_DRIVER=d3d12', 'A=it\'s "quoted"', 'B=a bc'])
})
