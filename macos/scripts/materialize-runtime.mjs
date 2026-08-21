#!/usr/bin/env node
/**
 * Post-process a `pnpm deploy --prod` tree: restore missing workspace packages,
 * replace package symlinks with real files, prune docs/tests, and chmod native
 * helpers. Usage: materialize-runtime.mjs <staging-dir> <workspace-root>
 */
import { existsSync, lstatSync, readdirSync, readFileSync } from 'node:fs'
import { chmod, cp, mkdir, readdir, realpath, rm, stat } from 'node:fs/promises'
import { dirname, join, sep } from 'node:path'

const PRUNE_FILES = new Set([
  'README.md',
  'README.zh.md',
  'README.i18n.yaml',
  'CHANGELOG.md',
])
const PRUNE_DIR_NAMES = new Set([
  'tests',
  '__tests__',
  'docs',
  '.github',
])

const staging = process.argv[2]
const workspace = process.argv[3]
if (!staging || !workspace) {
  console.error('usage: materialize-runtime.mjs <staging-dir> <workspace-root>')
  process.exit(1)
}

await restoreMissingPackages(staging, workspace)
await materializeLinks(join(staging, 'node_modules'))
await pruneTree(staging)
await chmodSpawnHelpers(staging)

function packageDestination(root, name) {
  return join(root, 'node_modules', ...name.split('/'))
}

function readManifest(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return null
  }
}

function dependencyNames(manifest) {
  return [
    ...Object.keys(manifest.dependencies ?? {}),
    ...Object.keys(manifest.peerDependencies ?? {}),
  ]
}

function collectWorkspacePackages(workspaceRoot) {
  const map = new Map()
  function visit(dir, depth) {
    if (depth > 3) return
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    const manifest = readManifest(join(dir, 'package.json'))
    if (manifest && typeof manifest.name === 'string') {
      map.set(manifest.name, dir)
    }
    for (const entry of entries) {
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
      if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue
      visit(join(dir, entry.name), depth + 1)
    }
  }
  visit(join(workspaceRoot, 'vendor'), 0)
  visit(join(workspaceRoot, 'apps'), 0)
  visit(join(workspaceRoot, 'packages'), 0)
  return map
}

function collectPnpmPackages(workspaceRoot) {
  const map = new Map()
  const pnpm = join(workspaceRoot, 'node_modules', '.pnpm')
  let entries
  try {
    entries = readdirSync(pnpm, { withFileTypes: true })
  } catch {
    return map
  }
  for (const entry of entries) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
    const nested = join(pnpm, entry.name, 'node_modules')
    let children
    try {
      children = readdirSync(nested, { withFileTypes: true })
    } catch {
      continue
    }
    for (const child of children) {
      if (child.name.startsWith('.')) continue
      if (child.name.startsWith('@')) {
        let scoped
        try {
          scoped = readdirSync(join(nested, child.name), { withFileTypes: true })
        } catch {
          continue
        }
        for (const inner of scoped) {
          const dir = join(nested, child.name, inner.name)
          const manifest = readManifest(join(dir, 'package.json'))
          if (manifest?.name) map.set(manifest.name, dir)
        }
        continue
      }
      const dir = join(nested, child.name)
      const manifest = readManifest(join(dir, 'package.json'))
      if (manifest?.name) map.set(manifest.name, dir)
    }
  }
  return map
}

function listManifests(root) {
  const found = [join(root, 'package.json')]
  function walk(dir) {
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const path = join(dir, entry.name)
      if (entry.name === '.pnpm') continue
      if (entry.isDirectory()) {
        if (entry.name === 'package.json') continue
        walk(path)
        continue
      }
      if (entry.name === 'package.json') found.push(path)
    }
  }
  walk(join(root, 'node_modules'))
  return found
}

async function copyPackage(source, destination) {
  await mkdir(dirname(destination), { recursive: true })
  const nestedNodeModules = join(source, 'node_modules')
  await cp(source, destination, {
    recursive: true,
    dereference: true,
    filter: (path) => path !== nestedNodeModules && !path.startsWith(nestedNodeModules + sep),
  })
}

async function restoreMissingPackages(root, workspaceRoot) {
  const workspacePackages = collectWorkspacePackages(workspaceRoot)
  const pnpmPackages = collectPnpmPackages(workspaceRoot)
  const restored = []
  let again = true
  while (again) {
    again = false
    for (const manifestPath of listManifests(root)) {
      const manifest = readManifest(manifestPath)
      if (!manifest) continue
      for (const dependency of dependencyNames(manifest)) {
        const destination = packageDestination(root, dependency)
        if (existsSync(destination)) continue
        const source = workspacePackages.get(dependency) ?? pnpmPackages.get(dependency)
        if (!source || source.startsWith(root + sep)) continue
        await copyPackage(source, destination)
        restored.push(dependency)
        again = true
      }
    }
  }
  if (restored.length > 0) {
    console.log(`[runtime] restored ${restored.length} missing packages`)
  } else {
    console.log('[runtime] no missing packages to restore')
  }
}

async function materializeLinks(nodeModules) {
  if (!existsSync(nodeModules)) {
    throw new Error(`deploy tree has no node_modules: ${nodeModules}`)
  }
  let remaining = findSymlinks(nodeModules)
  let replaced = 0
  while (remaining.length > 0) {
    const binDirs = new Set()
    const packages = []
    for (const link of remaining) {
      const segments = link.slice(nodeModules.length + 1).split(sep)
      const binIndex = segments.lastIndexOf('.bin')
      if (binIndex >= 0) {
        binDirs.add(join(nodeModules, ...segments.slice(0, binIndex + 1)))
        continue
      }
      packages.push(link)
    }
    for (const dir of binDirs) {
      await rm(dir, { recursive: true, force: true })
    }
    for (const destination of packages) {
      if (!existsSync(destination)) continue
      let source
      try {
        source = await realpath(destination)
      } catch {
        await rm(destination, { recursive: true, force: true })
        continue
      }
      const nestedNodeModules = join(source, 'node_modules')
      await rm(destination, { recursive: true, force: true })
      await cp(source, destination, {
        recursive: true,
        dereference: true,
        filter: (path) => path !== nestedNodeModules && !path.startsWith(nestedNodeModules + sep),
      })
      replaced += 1
    }
    remaining = findSymlinks(nodeModules)
  }
  console.log(`[runtime] materialized ${replaced} package links`)
}

function findSymlinks(directory) {
  const found = []
  function walk(current) {
    let entries
    try {
      entries = readdirSync(current, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const path = join(current, entry.name)
      let metadata
      try {
        metadata = lstatSync(path)
      } catch {
        continue
      }
      if (metadata.isSymbolicLink()) {
        found.push(path)
        continue
      }
      if (metadata.isDirectory()) walk(path)
    }
  }
  walk(directory)
  return found
}

async function pruneTree(root) {
  let removed = 0
  async function visit(directory, depth) {
    let entries
    try {
      entries = await readdir(directory, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const path = join(directory, entry.name)
      if (entry.isDirectory()) {
        const dropTypes = entry.name === 'types' && directory.endsWith(`${sep}lib`)
        if (depth > 0 && (PRUNE_DIR_NAMES.has(entry.name) || dropTypes)) {
          await rm(path, { recursive: true, force: true })
          removed += 1
          continue
        }
        await visit(path, depth + 1)
        continue
      }
      if (PRUNE_FILES.has(entry.name) || entry.name.endsWith('.map')) {
        await rm(path, { force: true })
        removed += 1
      }
    }
  }
  await visit(root, 0)
  console.log(`[runtime] pruned ${removed} build-only files/dirs`)
}

async function chmodSpawnHelpers(root) {
  const helpers = []
  async function visit(directory) {
    let entries
    try {
      entries = await readdir(directory, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const path = join(directory, entry.name)
      if (entry.isDirectory()) {
        await visit(path)
        continue
      }
      if (entry.name === 'spawn-helper' || entry.name === 'rg' || path.endsWith('.node')) {
        const info = await stat(path)
        if (info.isFile()) {
          await chmod(path, 0o755)
          helpers.push(path)
        }
      }
    }
  }
  await visit(root)
  console.log(`[runtime] chmod 755 on ${helpers.length} native helpers`)
}
