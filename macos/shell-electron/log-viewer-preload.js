// Log panel renderer bridge: the only channel is a stream of log lines
// pushed by the shell (main process). Sandboxed preload, so only the
// ipcRenderer/contextBridge subset of Electron is available.
'use strict'

const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('dshLog', {
  onLine(callback) {
    ipcRenderer.on('dsh-log-line', (_event, line) => callback(line))
  },
})
