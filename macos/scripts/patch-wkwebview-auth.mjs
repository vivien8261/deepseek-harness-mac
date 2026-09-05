#!/usr/bin/env node
/**
 * WKWebView does not reliably send SameSite=Strict cookies on WebSocket
 * upgrades. 0.1.3 authenticates `/api/remote.mux` with that cookie, so the
 * Mac shell can submit turns over HTTP while live journal updates stay blank.
 *
 * This post-process:
 * 1. Emits SameSite=Lax so same-origin WS may include the cookie.
 * 2. Accepts the process launch token on the upgrade URL as a fallback.
 *
 * Usage: patch-wkwebview-auth.mjs <dsh-staging-dir>
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const staging = process.argv[2]
if (!staging) {
  console.error('usage: patch-wkwebview-auth.mjs <dsh-staging-dir>')
  process.exit(1)
}

const target = join(
  staging,
  'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js',
)
if (!existsSync(target)) {
  console.error(`[runtime] ERROR: missing ${target}`)
  process.exit(1)
}

const original = readFileSync(target, 'utf8')
let next = original
const changes = []

const strictCookie = 'HttpOnly; SameSite=Strict'
const laxCookie = 'HttpOnly; SameSite=Lax'
if (next.includes(strictCookie)) {
  next = next.replaceAll(strictCookie, laxCookie)
  changes.push('SameSite=Lax')
} else if (!next.includes(laxCookie)) {
  console.error('[runtime] ERROR: sessionCookie SameSite marker not found')
  process.exit(1)
}

const unpatchedAuth = `isAuthenticated(request) {
		const authority = requestAuthority(request.headers);`
const patchedAuth = `hasLaunchToken(request) {
		const raw = typeof request.url === "string" ? request.url : void 0;
		if (raw === void 0) return false;
		try {
			const tokens = new URL(raw, "http://dsh.invalid").searchParams.getAll(TOKEN_QUERY);
			return tokens.length === 1 && tokenMatches(tokens[0], this.launchToken);
		} catch {
			return false;
		}
	}
	isAuthenticated(request) {
		if (this.hasLaunchToken(request)) return true;
		const authority = requestAuthority(request.headers);`

if (next.includes('hasLaunchToken(request)')) {
  // already patched
} else if (next.includes(unpatchedAuth)) {
  next = next.replace(unpatchedAuth, patchedAuth)
  changes.push('launch-token WebSocket auth')
} else {
  console.error('[runtime] ERROR: isAuthenticated() shape not found')
  process.exit(1)
}

if (next === original) {
  console.log('[runtime] WKWebView auth patch already applied')
  process.exit(0)
}

writeFileSync(target, next)
console.log(`[runtime] WKWebView auth patch: ${changes.join(', ')}`)
