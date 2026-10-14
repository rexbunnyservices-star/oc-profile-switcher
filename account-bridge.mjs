#!/usr/bin/env node
/**
 * Credential-free bridge between the Windows overlay and the existing
 * OpenCode multi-account manager.
 *
 * The normal widget path uses --daemon. One long-lived manager instance is
 * shared by all widget requests, but manager.reload() runs before every
 * operation so external OpenCode/TUI changes are observed immediately.
 * The one-shot command interface remains available for diagnostics/tests.
 *
 * No response contains credentials, raw auth entries, environment variables,
 * or access/refresh tokens.
 */
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { DatabaseSync } from "node:sqlite"
import readline from "node:readline"
import { fileURLToPath, pathToFileURL } from "node:url"

const home = os.homedir()
const managerPath = path.join(
  home,
  ".config",
  "opencode",
  "opencode-plugins",
  "opencode-multi-account-fixed",
  "dist",
  "account-manager.js",
)
const multiDir = path.join(home, ".config", "opencode", "multi-account")
const statusFile = path.join(multiDir, "last-session-status.json")
const healthFile = path.join(multiDir, "zen-key-health.json")
const dcpDir = path.join(home, ".local", "share", "opencode", "storage", "plugin", "dcp")
const dbFile = path.join(home, ".local", "share", "opencode", "opencode.db")
const widgetConfigFile = path.join(path.dirname(fileURLToPath(import.meta.url)), "widget-config.json")
// Context-window size per model id, used only as the limit for the context bar.
// Unknown models fall back to the widget-config budget.
const MODEL_CONTEXT_WINDOW = { "big-pickle": 200000, "space-bunny-free": 1000000 }
const SESSION_STATUS_MAX_AGE_MS = 15 * 60 * 1000
const CONTEXT_FRESH_MAX_AGE_MS = 5 * 60 * 1000

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function readJson(filePath) {
  try {
    const raw = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "")
    const value = JSON.parse(raw)
    return isRecord(value) ? value : null
  } catch {
    return null
  }
}

function finiteNumber(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value)
    if (Number.isFinite(parsed)) return parsed
  }
  return undefined
}

function firstNumber(...values) {
  for (const value of values) {
    const parsed = finiteNumber(value)
    if (parsed !== undefined) return parsed
  }
  return undefined
}

function safeSessionId(value) {
  const text = String(value ?? "").trim()
  if (!text || text.includes("\0") || path.basename(text) !== text) return null
  return text
}

function newestDcpFile() {
  try {
    const candidates = fs.readdirSync(dcpDir)
      .filter((name) => name.endsWith(".json"))
      .map((name) => {
        const filePath = path.join(dcpDir, name)
        const stat = fs.statSync(filePath)
        return { name, filePath, mtimeMs: stat.mtimeMs }
      })
      .sort((a, b) => b.mtimeMs - a.mtimeMs)
    return candidates[0] ?? null
  } catch {
    return null
  }
}

function queryDb(sql, ...params) {
  let db
  try {
    db = new DatabaseSync(dbFile, { readOnly: true })
    return db.prepare(sql).get(...params) ?? null
  } catch {
    return null
  } finally {
    try { db?.close() } catch { }
  }
}

function newestDbSessionId() {
  const row = queryDb("SELECT id FROM session ORDER BY time_updated DESC LIMIT 1")
  return row ? safeSessionId(row.id) : null
}

function sessionRow(sessionId) {
  const sid = safeSessionId(sessionId)
  if (!sid) return null
  return queryDb(
    "SELECT model, tokens_input, tokens_output, tokens_reasoning, time_updated FROM session WHERE id = ?",
    sid,
  )
}

function modelIdFrom(row) {
  try {
    const parsed = JSON.parse(String(row?.model ?? ""))
    return isRecord(parsed) && typeof parsed.id === "string" ? parsed.id : null
  } catch {
    return null
  }
}

function dbContextSnapshot(sessionId) {
  const empty = {
    available: false,
    tokens: null,
    limit: null,
    messageCount: 0,
    source: "opencode.db",
    updatedAt: null,
    fresh: false,
    reason: "no_session",
  }
  const sid = safeSessionId(sessionId)
  if (!sid) return empty
  const row = queryDb(
    "SELECT json_extract(data,'$.tokens.total') AS total, time_updated AS t" +
      " FROM message WHERE session_id = ? AND json_extract(data,'$.role')='assistant'" +
      " AND json_extract(data,'$.tokens.total') > 0 ORDER BY time_updated DESC LIMIT 1",
    sid,
  )
  const total = finiteNumber(row?.total)
  if (total === undefined) return { ...empty, reason: "no_token_counts" }
  const modelId = modelIdFrom(sessionRow(sid))
  const updatedMs = finiteNumber(row?.t)
  return {
    available: true,
    tokens: total,
    limit: (modelId && MODEL_CONTEXT_WINDOW[modelId]) || null,
    messageCount: 1,
    source: "opencode.db",
    updatedAt: updatedMs !== undefined ? new Date(updatedMs).toISOString() : null,
    fresh: updatedMs !== undefined && Math.max(0, Date.now() - updatedMs) <= CONTEXT_FRESH_MAX_AGE_MS,
    reason: null,
    model: modelId,
  }
}

function budgetSnapshot(sessionId) {
  const base = {
    available: false,
    used: null,
    limit: null,
    source: "opencode.db",
    updatedAt: null,
    fresh: false,
    reason: "no_session",
  }
  const sid = safeSessionId(sessionId)
  if (!sid) return base
  const row = sessionRow(sid)
  if (!row) return { ...base, reason: "session_not_found" }
  const used = (finiteNumber(row.tokens_input) ?? 0) +
    (finiteNumber(row.tokens_output) ?? 0) +
    (finiteNumber(row.tokens_reasoning) ?? 0)
  const cfg = readJson(widgetConfigFile)
  const cfgLimit = firstNumber(cfg?.localBudgetTokens)
  const updatedMs = finiteNumber(row.time_updated)
  return {
    available: used > 0,
    used,
    limit: cfgLimit !== undefined && cfgLimit > 0 ? cfgLimit : 1000000,
    source: "opencode.db",
    updatedAt: updatedMs !== undefined ? new Date(updatedMs).toISOString() : null,
    fresh: updatedMs !== undefined && Math.max(0, Date.now() - updatedMs) <= CONTEXT_FRESH_MAX_AGE_MS,
    reason: used > 0 ? null : "no_token_counts",
  }
}

function resolveSessionId(requested) {
  const explicit = safeSessionId(requested)
  if (explicit) return explicit

  try {
    const statusStat = fs.statSync(statusFile)
    if (Date.now() - statusStat.mtimeMs <= SESSION_STATUS_MAX_AGE_MS) {
      const status = readJson(statusFile)
      const event = isRecord(status?.event) ? status.event : null
      const properties = isRecord(event?.properties) ? event.properties : null
      const candidate = safeSessionId(properties?.sessionID ?? properties?.sessionId ?? properties?.info?.id)
      if (candidate) return candidate
    }
  } catch {
    // Fall through to the newest recorded session.
  }

  return newestDbSessionId() ?? newestDcpFile()?.name.replace(/\.json$/i, "") ?? null
}

function contextSnapshot(sessionId) {
  const empty = {
    available: false,
    tokens: null,
    messageCount: 0,
    source: "dcp",
    updatedAt: null,
    fresh: false,
    reason: "no_session",
  }
  const safeId = safeSessionId(sessionId)
  if (!safeId) return empty

  const filePath = path.join(dcpDir, `${safeId}.json`)
  let stat
  let data
  try {
    stat = fs.statSync(filePath)
    data = readJson(filePath)
  } catch {
    return dbContextSnapshot(safeId)
  }
  if (!data) return dbContextSnapshot(safeId)

  const prune = isRecord(data.prune) ? data.prune : {}
  const messages = isRecord(prune.messages) ? prune.messages : {}
  const byMessage = isRecord(messages.byMessageId) ? messages.byMessageId : {}
  const blocks = isRecord(messages.blocksById) ? messages.blocksById : {}
  const activeBlockIds = new Set(
    (Array.isArray(messages.activeBlockIds) ? messages.activeBlockIds : [])
      .map((value) => String(value)),
  )

  let total = 0
  let messageCount = 0
  for (const [messageId, rawRecord] of Object.entries(byMessage)) {
    const record = isRecord(rawRecord) ? rawRecord : {}
    const tokenCount = finiteNumber(record.tokenCount)
    if (tokenCount === undefined) continue
    const recordBlockIds = Array.isArray(record.activeBlockIds)
      ? record.activeBlockIds.map((value) => String(value))
      : []
    const isActive = activeBlockIds.size === 0 || recordBlockIds.some((id) => activeBlockIds.has(id))
    if (isActive) {
      total += tokenCount
      messageCount += 1
    }
  }

  const updatedAt = typeof data.lastUpdated === "string" ? data.lastUpdated : new Date(stat.mtimeMs).toISOString()
  const age = Math.max(0, Date.now() - stat.mtimeMs)
  const fresh = age <= CONTEXT_FRESH_MAX_AGE_MS

  // Message-level token counts are the preferred source. If an older DCP
  // shape has no active message counts, use active block compressed counts
  // rather than selecting an arbitrary/last JSON property.
  if (messageCount > 0) {
    return {
      available: true,
      tokens: total,
      messageCount,
      source: "dcp-active-messages",
      updatedAt,
      fresh,
      reason: null,
    }
  }

  let compressedTotal = 0
  let blockCount = 0
  for (const [blockKey, rawBlock] of Object.entries(blocks)) {
    if (activeBlockIds.size > 0 && !activeBlockIds.has(blockKey)) continue
    const block = isRecord(rawBlock) ? rawBlock : {}
    const compressed = finiteNumber(block.compressedTokens)
    if (compressed === undefined) continue
    compressedTotal += compressed
    blockCount += 1
  }
  if (blockCount > 0) {
    return {
      available: true,
      tokens: compressedTotal,
      messageCount: 0,
      blockCount,
      source: "dcp-active-blocks",
      updatedAt,
      fresh,
      reason: null,
    }
  }

  return dbContextSnapshot(safeId)
}

function keyHealthSnapshot() {
  const base = {
    available: false,
    total: null,
    pass: null,
    ok: null,
    checkedAt: null,
    source: "zen-key-health.json",
    reason: "not_configured",
  }
  let stat
  try {
    stat = fs.statSync(healthFile)
  } catch {
    return base
  }

  const root = readJson(healthFile)
  if (!root) return { ...base, reason: "invalid_file" }
  const total = firstNumber(root.total)
  const pass = firstNumber(root.pass)
  if (total === undefined || total <= 0) return { ...base, reason: "incomplete" }

  const checkedAt = firstNumber(root.checkedAt)
  const observedAt = checkedAt !== undefined ? checkedAt : stat.mtimeMs
  return {
    available: true,
    total,
    pass: pass ?? 0,
    ok: root.ok === true,
    checkedAt: new Date(observedAt).toISOString(),
    ageMs: Math.max(0, Date.now() - observedAt),
    source: "zen-key-health.json",
    reason: null,
  }
}

function cleanAccount(item) {
  return {
    id: String(item.id),
    name: String(item.name),
    provider: String(item.provider),
    priority: Number(item.priority),
    status: String(item.status),
    cooldownRemainingMs: Number(item.cooldownRemainingMs) || 0,
    selectable: Boolean(item.selectable),
    isGlobalCurrent: Boolean(item.isGlobalCurrent),
    isSessionCurrent: Boolean(item.isSessionCurrent),
  }
}

function cleanSnapshot(snapshot, sessionId) {
  return {
    sessionId: sessionId ?? snapshot.sessionId ?? null,
    currentAccountId: snapshot.currentAccountId ?? null,
    sessionAccountId: snapshot.sessionAccountId ?? null,
    accounts: (snapshot.accounts ?? []).map(cleanAccount),
    tracking: {
      totalRateLimitEvents: Number(snapshot.tracking?.totalRateLimitEvents) || 0,
      totalRotations: Number(snapshot.tracking?.totalRotations) || 0,
      totalManualSwitches: Number(snapshot.tracking?.totalManualSwitches) || 0,
      lastRateLimitAt: snapshot.tracking?.lastRateLimitAt ?? null,
      lastRotationAt: snapshot.tracking?.lastRotationAt ?? null,
      lastManualSwitchAt: snapshot.tracking?.lastManualSwitchAt ?? null,
      lastRotationReason: snapshot.tracking?.lastRotationReason ?? null,
      lastRotationSource: snapshot.tracking?.lastRotationSource ?? null,
    },
    lastUpdated: snapshot.lastUpdated ?? null,
  }
}

function enrichedSnapshot(manager, requestedSessionId) {
  // This is deliberately before every read. The manager is shared in the
  // daemon, but reload() makes external TUI/server changes immediately visible.
  manager.reload()
  const sessionId = resolveSessionId(requestedSessionId)
  const snapshot = manager.getTrackingSnapshot(sessionId ?? undefined)
  return {
    ...cleanSnapshot(snapshot, sessionId),
    observedAt: new Date().toISOString(),
    context: contextSnapshot(sessionId),
    quota: budgetSnapshot(sessionId),
    keyHealth: keyHealthSnapshot(),
  }
}

function cleanSwitchedAccount(account) {
  if (!account) return null
  return {
    id: String(account.id),
    name: String(account.name),
    provider: String(account.provider),
  }
}

function execute(manager, request) {
  const command = String(request.command ?? "snapshot")
  if (command === "snapshot") {
    return { ok: true, snapshot: enrichedSnapshot(manager, request.sessionId) }
  }

  if (command === "switch") {
    const accountId = String(request.accountId ?? "")
    const scope = String(request.scope ?? "global")
    const sessionId = safeSessionId(request.sessionId)
    if (!accountId) throw new Error("Account id is required")
    if (scope !== "global" && scope !== "session") throw new Error("Invalid switch scope")
    if (scope === "session" && !sessionId) throw new Error("A session id is required for session scope")

    // Reload immediately before mutation, then reload again before returning
    // the display snapshot. The manager's atomic state/auth writes remain the
    // source of truth; no widget-side token or credential cache is introduced.
    manager.reload()
    const result = manager.switchToAccount(accountId, scope === "session" ? sessionId : undefined, {
      scope,
      tracking: "manual",
      source: "windows-widget",
    })
    manager.reload()
    const snapshot = enrichedSnapshot(manager, scope === "session" ? sessionId : undefined)
    return {
      ok: Boolean(result.account),
      reason: result.reason ?? null,
      account: cleanSwitchedAccount(result.account),
      snapshot,
    }
  }

  throw new Error(`Unknown command: ${command}`)
}

function usage(message) {
  return String(message ?? "Unknown bridge error").replace(/[\r\n]+/g, " ").slice(0, 240)
}

async function loadManager() {
  const mod = await import(pathToFileURL(managerPath).href)
  if (!mod || typeof mod.AccountManager !== "function") {
    throw new Error("OpenCode account manager is unavailable")
  }
  return mod.AccountManager
}

async function runDaemon() {
  const AccountManager = await loadManager()
  const manager = new AccountManager()
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity })
  for await (const line of input) {
    if (!line.trim()) continue
    let request = {}
    let requestId = null
    try {
      request = JSON.parse(line)
      requestId = request.id ?? null
      const result = execute(manager, request)
      process.stdout.write(JSON.stringify({ id: requestId, ...result }) + "\n")
    } catch (error) {
      process.stdout.write(JSON.stringify({ id: requestId, ok: false, error: usage(error?.message) }) + "\n")
    }
  }
}

async function runOnce() {
  const [command = "snapshot", accountId, scope = "global", sessionId] = process.argv.slice(2)
  const AccountManager = await loadManager()
  const manager = new AccountManager()
  const result = execute(manager, { command, accountId, scope, sessionId })
  process.stdout.write(JSON.stringify({ ok: true, ...result }))
}

const isDaemon = process.argv.slice(2).some((arg) => arg === "--daemon")
if (isDaemon) {
  runDaemon().catch((error) => {
    process.stderr.write(usage(error?.message))
    process.exitCode = 1
  })
} else {
  runOnce().catch((error) => {
    process.stdout.write(JSON.stringify({ ok: false, error: usage(error?.message) }))
    process.exitCode = 1
  })
}
