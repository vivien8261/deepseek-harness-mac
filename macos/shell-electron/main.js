// DeepSeek Harness — Electron shell.
//
// Spawns the bundled dsh web server (same runtime the AppKit shell uses),
// waits for the `dsh web:` readiness line, and opens that URL in a Chromium
// window. A Chromium shell is used instead of WKWebView because the harness
// frontend's assistant-stream handling depends on browser object semantics
// that WebKit violates (repeated "Assistant stream raw chunk must be a
// lossless JSON object" failures, blank transcript); Chrome and Electron
// share the engine and are unaffected.
'use strict'

const { app, BrowserWindow, Menu, shell } = require('electron')
const { spawn } = require('node:child_process')
const { join, dirname } = require('node:path')
const fs = require('node:fs')
const os = require('node:os')
const net = require('node:net')
const { pathToFileURL, fileURLToPath } = require('node:url')

const PORT_RANGE = { start: 3080, end: 3180 }
const READY_RE = /dsh web:\s+(https?:\/\/[^\s]+)/

let mainWindow = null
let server = null
let serverPort = 0
let serverToken = null
let logHandle = null

// ---------------------------------------------------------------------------
// Logging (mirrors the AppKit shell: ~/Library/Logs/DeepSeekHarness.log)
// ---------------------------------------------------------------------------

function logLine(message) {
  const line = `${new Date().toISOString()} ${message}\n`
  process.stdout.write(line)
  try {
    if (!logHandle) {
      const dir = join(os.homedir(), 'Library/Logs')
      fs.mkdirSync(dir, { recursive: true })
      logHandle = fs.openSync(join(dir, 'DeepSeekHarness.log'), 'a')
    }
    fs.writeSync(logHandle, line)
  } catch (error) {
    // Diagnostics must never take the shell down.
  }
}

// ---------------------------------------------------------------------------
// Bundled runtime discovery
// ---------------------------------------------------------------------------

function resourcesPath() {
  if (process.env.DSH_ELECTRON_RESOURCES) return process.env.DSH_ELECTRON_RESOURCES
  // process.resourcesPath = <app>/Contents/Resources
  return process.resourcesPath
}

function bundledRuntime() {
  const resources = resourcesPath()
  const nodeExecutable = join(resources, 'node/bin/node')
  const binScript = join(resources, 'dsh/lib/bin.js')
  if (!fs.existsSync(nodeExecutable) || !fs.existsSync(binScript)) {
    throw new Error(`bundled runtime missing under ${resources}`)
  }
  return { nodeExecutable, binScript, resources }
}

function runtimeManifest(resources) {
  try {
    return JSON.parse(fs.readFileSync(join(resources, 'runtime.json'), 'utf8'))
  } catch {
    return {}
  }
}

// ---------------------------------------------------------------------------
// Server lifecycle
// ---------------------------------------------------------------------------

function firstFreePort(start, end) {
  for (let port = start; port <= end; port += 1) {
    if (isPortFree(port)) return port
  }
  return null
}

function isPortFree(port) {
  // Use a connect probe, not bind: binding with SO_REUSEADDR can succeed on a
  // port another listener already holds on macOS, which then makes the dsh
  // server crash with EADDRINUSE after we picked that "free" port.
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port, timeout: 500 })
    socket.once('connect', () => {
      socket.destroy()
      resolve(false)
    })
    socket.once('timeout', () => {
      socket.destroy()
      resolve(true)
    })
    socket.once('error', () => resolve(true))
  })
}

async function cleanupOwnedOrphan() {
  // Only a previously recorded dsh web server is ever reclaimed; a
  // user-launched `dsh web` never writes this lock file.
  const lockPath = join(os.homedir(), '.dsh', '.dsh-web-macos.json')
  let record
  try {
    record = JSON.parse(fs.readFileSync(lockPath, 'utf8'))
  } catch {
    return
  }
  if (!Number.isSafeInteger(record.pid) || record.pid <= 0) return
  const alive = process.kill(record.pid, 0) === true || process.kill(record.pid, 0) === undefined
  if (!alive) {
    try { fs.rmSync(lockPath) } catch {}
    return
  }
  logLine(`terminating orphaned dsh web pid=${record.pid}`)
  try { process.kill(-record.pid, 'SIGTERM') } catch { /* not a group leader */ }
  try { process.kill(record.pid, 'SIGTERM') } catch {}
  setTimeout(() => {
    try { process.kill(-record.pid, 'SIGKILL') } catch {}
    try { process.kill(record.pid, 'SIGKILL') } catch {}
  }, 5000)
  try { fs.rmSync(lockPath) } catch {}
}

function writeOwnershipLock() {
  try {
    const dir = join(os.homedir(), '.dsh')
    fs.mkdirSync(dir, { recursive: true })
    const payload = {
      pid: server?.pid ?? 0,
      port: serverPort,
      startedAt: new Date().toISOString(),
    }
    fs.writeFileSync(join(dir, '.dsh-web-macos.json'), JSON.stringify(payload))
  } catch {
    // non-fatal
  }
}

function clearOwnershipLock() {
  try {
    fs.rmSync(join(os.homedir(), '.dsh', '.dsh-web-macos.json'))
  } catch {}
}

function startServer() {
  return new Promise(async (resolve, reject) => {
    let runtime
    try {
      runtime = bundledRuntime()
    } catch (error) {
      reject(error)
      return
    }
    const manifest = runtimeManifest(runtime.resources)
    const port = await firstFreePort(PORT_RANGE.start, PORT_RANGE.end)
    if (port === null) {
      reject(new Error('no free port in 3080-3180'))
      return
    }

    const environment = {
      ...process.env,
      CI: '1',
      FORCE_COLOR: '0',
      PATH: `${dirname(runtime.nodeExecutable)}:${process.env.PATH ?? '/usr/bin:/bin:/usr/sbin:/sbin'}`,
    }
    if (environment.HOME == null) environment.HOME = os.homedir()

    const args = [
      runtime.binScript, 'web', '--host', '127.0.0.1', '--port', String(port), '--no-open',
    ]

    logLine(`starting port=${port} cwd=${environment.HOME} node=${runtime.nodeExecutable} version=${manifest.version ?? 'unknown'}`)
    logLine(`执行：${runtime.nodeExecutable} ${args.join(' ')}`)
    logLine(`鉴权补丁：${manifest.authPatch === 'applied' ? '已应用' : `缺失（${manifest.authPatch ?? 'unknown'}）`}`)

    const child = spawn(runtime.nodeExecutable, args, {
      cwd: environment.HOME,
      env: environment,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    server = child
    serverPort = port
    writeOwnershipLock()

    let output = ''
    const onData = (chunk) => {
      const text = chunk.toString('utf8').replace(/\u001B\[[0-9;?]*[A-Za-z]/g, '')
      output += text
      // Mirror everything to the log file, including post-ready console.log.
      for (const line of text.split('\n')) {
        if (line.trim() !== '') logLine(`[dsh] ${line}`)
      }
      const match = READY_RE.exec(output)
      if (match) {
        serverToken = match[1]
        resolve(match[1])
      }
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', onData)

    child.on('exit', () => {
      server = null
      clearOwnershipLock()
      if (mainWindow && !mainWindow.isDestroyed()) {
        // Keep the window; the user may retry.
      }
    })

    setTimeout(() => {
      if (!serverToken) {
        reject(new Error('server did not print a ready URL within 30s'))
        try { child.kill('SIGKILL') } catch {}
      }
    }, 30000).unref()
  })
}

function stopServer() {
  const child = server
  server = null
  if (!child) return
  try { process.kill(-child.pid, 'SIGTERM') } catch { /* not a group leader */ }
  try { child.kill('SIGTERM') } catch {}
  const deadline = Date.now() + 5000
  const timer = setInterval(() => {
    if (child.exitCode !== null) {
      clearInterval(timer)
      return
    }
    if (Date.now() > deadline) {
      try { process.kill(-child.pid, 'SIGKILL') } catch {}
      try { child.kill('SIGKILL') } catch {}
      clearInterval(timer)
    }
  }, 200)
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

function createWindow(url) {
  const manifest = runtimeManifest(resourcesPath())
  const appTitle = manifest.version
    ? `DeepSeek Harness  ·  ${manifest.version}`
    : 'DeepSeek Harness'

  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    title: appTitle,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  // Keep the fixed app title; the page (and its dynamic document.title) must
  // not retitle the window.
  mainWindow.on('page-title-updated', (event) => { event.preventDefault() })

  const origin = new URL(url).origin

  // Mirror the AppKit shell's navigation policy:
  // - dsh-service URLs (same origin) and in-page resources (about/blob/data) stay in the shell;
  // - every other scheme/authority is handed to the system browser and the
  //   in-shell navigation is cancelled.
  const handOff = (target) => {
    let parsed
    try {
      parsed = new URL(target, origin)
    } catch {
      return false
    }
    const scheme = parsed.protocol
    if (scheme === 'about:' || scheme === 'blob:' || scheme === 'data:') return false
    if (scheme === 'http:' || scheme === 'https:') {
      if (parsed.origin === origin) return false
      shell.openExternal(parsed.href)
      return true
    }
    if (scheme === 'mailto:' || scheme.startsWith('tel:') || scheme.startsWith('ftp:')) {
      shell.openExternal(parsed.href)
      return true
    }
    // Unknown schemes: do not navigate inside the shell.
    return true
  }

  mainWindow.webContents.setWindowOpenHandler(({ url: target }) => {
    // Same-service popups behave like the AppKit shell: keep them in the shell
    // window; external handoffs were already dispatched by handOff().
    if (!handOff(target)) mainWindow.webContents.loadURL(target)
    return { action: 'deny' }
  })
  mainWindow.webContents.on('will-navigate', (event, target) => {
    if (handOff(target)) event.preventDefault()
  })

  mainWindow.loadURL(url)
  mainWindow.on('closed', () => { mainWindow = null })
}

function buildMenu() {
  const isMac = process.platform === 'darwin'
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
      ],
    },
    {
      role: 'help',
      submenu: [
        {
          label: '打开日志文件',
          click: () => {
            shell.openPath(join(os.homedir(), 'Library/Logs', 'DeepSeekHarness.log'))
          },
        },
      ],
    },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  })

  app.whenReady().then(async () => {
    buildMenu()
    try {
      await cleanupOwnedOrphan()
      const url = await startServer()
      createWindow(url)
    } catch (error) {
      logLine(`startup failed: ${error.message}`)
      const dialog = require('electron').dialog
      dialog.showErrorBox('DeepSeek Harness', `本地服务启动失败：\n${error.message}`)
      app.quit()
    }

    app.on('activate', () => {
      if (mainWindow) mainWindow.show()
    })
  })

  app.on('window-all-closed', () => {
    stopServer()
    clearOwnershipLock()
    app.quit()
  })

  app.on('before-quit', () => {
    stopServer()
    clearOwnershipLock()
  })
}
