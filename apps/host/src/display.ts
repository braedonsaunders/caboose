import type { DisplayProtocol } from './config.js'

/**
 * The owner's display server inside the computer, by the protocol the app speaks to it:
 * the guest port the display relay opens, and the environment an app launched onto it
 * needs. Xpra serves X display :100 on 14500. caboose-display (docs/display.md) serves its
 * Wayland socket, plus Xwayland on :110 for X11 apps, on 14600. The agent seat stays Xpra
 * :101 on 14501 either way.
 */
export interface OwnerDisplay {
  port: number
  launchEnv: string[]
}

export const OWNER_DISPLAYS: Record<DisplayProtocol, OwnerDisplay> = {
  'xpra-ws': { port: 14500, launchEnv: ['DISPLAY=:100'] },
  'caboose-display': {
    port: 14600,
    launchEnv: [
      'XDG_RUNTIME_DIR=/run/user/1000', 'WAYLAND_DISPLAY=wayland-caboose-0', 'DISPLAY=:110',
      // Native Wayland wherever a toolkit has it, X11 through Xwayland otherwise.
      'GDK_BACKEND=wayland,x11', 'QT_QPA_PLATFORM=wayland;xcb', 'MOZ_ENABLE_WAYLAND=1', 'SDL_VIDEODRIVER=wayland,x11',
      'ELECTRON_OZONE_PLATFORM_HINT=auto',
    ],
  },
}
