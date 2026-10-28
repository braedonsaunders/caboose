import * as React from 'react'
import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App.js'
import { theme } from './theme.js'

try {
  const stored = window.localStorage.getItem(theme.storageKey)
  const resolved =
    stored === 'light' || stored === 'dark'
      ? stored
      : stored === 'system'
        ? window.matchMedia('(prefers-color-scheme: dark)').matches
          ? 'dark'
          : 'light'
        : theme.defaultTheme
  document.documentElement.classList.toggle('dark', resolved === 'dark')
  document.documentElement.style.colorScheme = resolved
} catch {
  // Keep default dark class when localStorage is unavailable.
}

const container = document.getElementById('root')
if (!container) {
  throw new Error('Missing #root container')
}

createRoot(container).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
