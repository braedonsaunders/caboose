// The Electron scroll reporter check's application (check.py electron-scroll-reports): one
// window showing the ruler page guest/display/probe/src/scroll.rs reads back.
const path = require('node:path')
const { app, BrowserWindow } = require('electron')
app.whenReady().then(() => {
  const window = new BrowserWindow({ width: 900, height: 800, title: 'ruler' })
  // Electron turns pinch zoom off unless an application allows it, as this one does.
  window.webContents.setVisualZoomLevelLimits(1, 4)
  window.loadFile(path.join(__dirname, '..', '..', '..', 'display', 'scripts', 'pages', 'scroll-ruler.html'))
})
