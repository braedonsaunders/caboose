// The Electron scroll reporter check's application (check.py electron-scroll-reports): one
// window showing the ruler page guest/display/probe/src/scroll.rs reads back.
const path = require('node:path')
const { app, BrowserWindow } = require('electron')
app.whenReady().then(() => {
  const window = new BrowserWindow({ width: 900, height: 800, title: 'ruler' })
  window.loadFile(path.join(__dirname, '..', '..', '..', 'display', 'scripts', 'pages', 'scroll-ruler.html'))
})
