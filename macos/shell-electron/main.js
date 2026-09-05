// DeepSeek Harness — Electron shell.
//
// Spawns the bundled dsh web server (same runtime the AppKit shell uses),
// waits for the `dsh web:` readiness line, and opens that URL in a Chromium
// window. A Chromium shell is used instead of WKWebView because the harness
// frontend's assistant-stream handling depends on browser object semantics
// that WebKit violates (repeated "Assistant stream raw chunk must be a
// lossless JSON object" failures, blank transcript); Chrome and Electron
// share the engine and are unaffected.
//
// UX notes (mirrors the AppKit shell where it makes sense):
// - Edit/Window menus + ⌘L log panel, so clipboard and window shortcuts work;
// - window frames are persisted across launches;
// - the window only appears once the page is ready (no white flash);
// - when the dsh server exits unexpectedly the user gets a retry dialog.
'use strict'

const { app, BrowserWindow, Menu, dialog, nativeTheme, shell, screen } = require('electron')
const { spawn } = require('node:child_process')
const { join, dirname } = require('node:path')
const fs = require('node:fs')
const os = require('node:os')
const net = require('node:net')

const PORT_RANGE = { start: 3080, end: 3180 }
const READY_RE = /dsh web:\s+(https?:\/\/[^\s]+)/
const MAX_LOG_BUFFER = 200000

let mainWindow = null
let logWindow = null
let logWindowReady = false
let logBuffer = ''
let server = null
let serverPort = 0
let serverToken = null
let logHandle = null
let quitInProgress = false
let serverDownPromptShown = false

// ---------------------------------------------------------------------------
// Logging (mirrors the AppKit shell: ~/Library/Logs/DeepSeekHarness.log)
// ---------------------------------------------------------------------------

function logLine(message) {
  const line = `${new Date().toISOString()} ${message}\n`
  logBuffer += line
  if (logBuffer.length > MAX_LOG_BUFFER) logBuffer = logBuffer.slice(-MAX_LOG_BUFFER * 4 / 5)
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
  if (logWindow && logWindowReady && !logWindow.isDestroyed()) {
    logWindow.webContents.send('dsh-log-line', line)
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

    child.on('exit', (code, signal) => {
      server = null
      serverToken = null
      clearOwnershipLock()
      if (quitInProgress) return
      logLine(`dsh web exited unexpectedly code=${code} signal=${signal ?? 'none'}`)
      // Debounce: a single crash can fire more than one exit/close event.
      if (serverDownPromptShown) return
      serverDownPromptShown = true
      setTimeout(() => {
        serverDownPromptShown = false
        promptServerDown()
      }, 800)
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

async function restartServer() {
  logLine('restarting dsh web…')
  stopServer()
  serverToken = null
  try {
    const url = await startServer()
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.loadURL(url)
  } catch (error) {
    logLine(`restart failed: ${error.message}`)
    if (mainWindow && !mainWindow.isDestroyed()) {
      dialog.showMessageBox(mainWindow, {
        type: 'error',
        title: 'DeepSeek Harness',
        message: '本地服务重启失败',
        detail: error.message,
        buttons: ['确定'],
      })
    }
  }
}

function promptServerDown() {
  const parent = mainWindow && !mainWindow.isDestroyed() ? mainWindow : undefined
  const options = {
    type: 'warning',
    title: 'DeepSeek Harness',
    message: '本地 dsh 服务已意外退出',
    detail: '页面可能无法继续工作。可以重启服务，或查看日志了解原因。',
    buttons: ['重启服务', '查看日志', '退出'],
    defaultId: 0,
    cancelId: 2,
  }
  const finish = (response) => {
    if (response === 0) { restartServer(); return }
    if (response === 1) { toggleLogPanel(); return }
    quitInProgress = true
    app.quit()
  }
  if (parent) {
    dialog.showMessageBox(parent, options).then(({ response }) => finish(response))
  } else {
    dialog.showMessageBox(options).then(({ response }) => finish(response))
  }
}

// ---------------------------------------------------------------------------
// Window state persistence
// ---------------------------------------------------------------------------

function windowStatePath() {
  return join(app.getPath('userData'), 'window-state.json')
}

function loadWindowState() {
  try {
    const state = JSON.parse(fs.readFileSync(windowStatePath(), 'utf8'))
    if (typeof state.width !== 'number' || typeof state.height !== 'number') return null
    if (state.width < 900 || state.height < 600) return null
    const x = typeof state.x === 'number' ? state.x : 0
    const y = typeof state.y === 'number' ? state.y : 0
    // If the saved frame is off every screen (e.g. a display was unplugged),
    // keep only the size and let the OS place the window.
    const onScreen = screen.getAllDisplays().some((display) => {
      const area = display.workArea
      return x < area.x + area.width && x + state.width > area.x &&
             y < area.y + area.height && y + state.height > area.y
    })
    if (!onScreen) return { width: state.width, height: state.height }
    return { x, y, width: state.width, height: state.height }
  } catch {
    return null
  }
}

let stateSaveTimer = null

function saveWindowStateNow() {
  if (!mainWindow || mainWindow.isDestroyed()) return
  try {
    const bounds = mainWindow.getNormalBounds()
    fs.writeFileSync(windowStatePath(), JSON.stringify(bounds))
  } catch {
    // non-fatal
  }
}

function scheduleWindowStateSave() {
  clearTimeout(stateSaveTimer)
  stateSaveTimer = setTimeout(saveWindowStateNow, 600)
}

// ---------------------------------------------------------------------------
// Log panel (⌘L)
// ---------------------------------------------------------------------------

function toggleLogPanel() {
  if (logWindow && !logWindow.isDestroyed()) {
    if (logWindow.isVisible()) {
      logWindow.hide()
      return
    }
    logWindow.show()
    logWindow.focus()
    return
  }
  createLogWindow()
}

function createLogWindow() {
  logWindowReady = false
  logWindow = new BrowserWindow({
    width: 980,
    height: 560,
    minWidth: 480,
    minHeight: 240,
    title: '运行日志',
    show: false,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#15171c' : '#ffffff',
    webPreferences: {
      preload: join(__dirname, 'log-viewer-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  logWindow.setAutoHideMenuBar(true)
  logWindow.loadFile(join(__dirname, 'log-viewer.html'))
  logWindow.webContents.on('did-finish-load', () => {
    logWindowReady = true
    logWindow.webContents.send('dsh-log-line', logBuffer)
    logWindow.show()
  })
  logWindow.on('closed', () => {
    logWindow = null
    logWindowReady = false
  })
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

function createWindow(url) {
  const manifest = runtimeManifest(resourcesPath())
  const appTitle = manifest.version
    ? `DeepSeek Harness  ·  ${manifest.version}`
    : 'DeepSeek Harness'

  const state = loadWindowState()
  mainWindow = new BrowserWindow({
    ...(state?.x != null && state?.y != null ? { x: state.x, y: state.y } : {}),
    width: state?.width ?? 1280,
    height: state?.height ?? 800,
    minWidth: 900,
    minHeight: 600,
    title: appTitle,
    // Show only once the page has painted, so the user never sees a blank
    // window flash (fall back to showing after 15s no matter what).
    show: false,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#15171c' : '#ffffff',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  const showTimer = setTimeout(() => {
    if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.isVisible()) mainWindow.show()
  }, 15000)
  showTimer.unref()
  mainWindow.once('ready-to-show', () => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.show()
  })

  mainWindow.on('resize', scheduleWindowStateSave)
  mainWindow.on('move', scheduleWindowStateSave)
  mainWindow.on('close', () => {
    clearTimeout(stateSaveTimer)
    saveWindowStateNow()
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

  // Right-click menu: a Chromium shell ships no default context menu, so
  // expose the standard edit commands here (⌘C/⌘V/⌘X keep working via the
  // Edit menu; this covers mouse users and the non-mac case).
  mainWindow.webContents.on('context-menu', (event, params) => {
    const items = [
      { role: 'undo', enabled: params.editFlags.canUndo },
      { role: 'redo', enabled: params.editFlags.canRedo },
      { type: 'separator' },
      { role: 'cut', enabled: params.editFlags.canCut },
      { role: 'copy', enabled: params.editFlags.canCopy },
      { role: 'paste', enabled: params.editFlags.canPaste },
      { role: 'selectAll', enabled: params.editFlags.canSelectAll },
    ]
    Menu.buildFromTemplate(items).popup({ window: mainWindow })
  })

  mainWindow.webContents.on('did-fail-load', (event, errorCode, errorDescription, validatedURL) => {
    logLine(`page load failed: ${errorDescription} (${errorCode}) ${validatedURL}`)
    if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.isVisible()) mainWindow.show()
  })

  mainWindow.loadURL(url)
  mainWindow.on('closed', () => { mainWindow = null })
}

// ---------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------

function menuLabels() {
  const zh = /^zh/i.test(app.getLocale())
  return {
    edit: zh ? '编辑' : 'Edit',
    view: zh ? '显示' : 'View',
    window: zh ? '窗口' : 'Window',
    help: zh ? '帮助' : 'Help',
    serverLogs: zh ? '服务日志' : 'Server Logs',
    openLogFile: zh ? '打开日志文件' : 'Open Log File',
  }
}

function buildMenu() {
  const isMac = process.platform === 'darwin'
  const L = menuLabels()
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: L.edit,
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'delete' },
        ...(isMac ? [{ type: 'separator' }, { role: 'selectAll' }] : [{ role: 'selectAll' }]),
      ],
    },
    {
      label: L.view,
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { type: 'separator' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        {
          label: L.serverLogs,
          accelerator: 'CmdOrCtrl+L',
          click: () => toggleLogPanel(),
        },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
      ],
    },
    ...(isMac
      ? [{ role: 'windowMenu', label: L.window }]
      : [{ role: 'window', label: L.window }]),
    {
      role: 'help',
      label: L.help,
      submenu: [
        {
          label: L.openLogFile,
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
    let url = null
    try {
      await cleanupOwnedOrphan()
      url = await startServer()
    } catch (error) {
      quitInProgress = true
      logLine(`service startup failed: ${error.message}`)
      dialog.showErrorBox(
        'DeepSeek Harness',
        `本地服务启动失败：\n${error.message}\n\n详情见日志：~/Library/Logs/DeepSeekHarness.log`
      )
      app.quit()
      return
    }
    try {
      createWindow(url)
    } catch (error) {
      quitInProgress = true
      logLine(`window startup failed: ${error.message}`)
      dialog.showErrorBox(
        'DeepSeek Harness',
        `窗口启动失败：\n${error.message}\n\n详情见日志：~/Library/Logs/DeepSeekHarness.log`
      )
      app.quit()
      return
    }

    app.on('activate', () => {
      if (mainWindow) mainWindow.show()
    })
  })

  app.on('window-all-closed', () => {
    quitInProgress = true
    stopServer()
    clearOwnershipLock()
    app.quit()
  })

  app.on('before-quit', () => {
    quitInProgress = true
    stopServer()
    clearOwnershipLock()
  })
}
