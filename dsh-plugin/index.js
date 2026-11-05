// p2bot bridge: this DeepSeek Harness host asks the paper2brain server for calls p2bot's page makes (list the sessions,
// read one, send it a message, stop it…), runs them on the host's own API and sends the answers back. The host stays the
// only one that writes its sessions, so the desktop and the phone see one live conversation. It connects out with this
// Mac's paper2brain-client token (~/.paper2brain-client/config.json), as the runner does; nothing listens here.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

export const name = 'p2bot-bridge'
export const inject = ['typertGateway', 'connection']

// what the page may ask for; anything else is refused here too (the server checks the same list)
export const ALLOW = new Set([
  'session.list', 'session.create', 'session.prompt', 'session.cancel', 'session.page', 'session.state',
  'session.modelCatalog', 'session.selectModel', 'session.rename', 'p2bot.token', 'p2bot.pending', 'p2bot.answer',
  // the desktop's navigation (workspaces group the sessions; archiving is its delete) and its background jobs
  'p2bot.workspaces', 'p2bot.jobs', 'workspace.rename', 'workspace.pinSession', 'workspace.unpinSession',
  'workspace.archiveSession', 'workspace.unarchiveSession', 'job.kill', 'workspace.create', 'workspace.delete',
])

function settings() {
  const home = process.env.P2B_CLIENT_HOME || path.join(os.homedir(), '.paper2brain-client')
  const cfg = JSON.parse(fs.readFileSync(path.join(home, 'config.json'), 'utf8'))
  return { server: String(cfg.server || '').replace(/\/+$/, ''), token: String(cfg.server_token || '') }
}

/** A p2bot task's turn run on this host: its token into the task folder's bin/p2bot (written by the runner on the task's first
 * turn), so the agent's `./bin/p2bot put` hands files back to this turn. Only that one line of that one file changes. */
export function writeToken({ task, token } = {}) {
  if (!/^[0-9a-f]{16}$/.test(task || '') || !/^[A-Za-z0-9._-]{20,300}$/.test(token || '')) return { ok: false, error: 'bad task or token' }
  const file = path.join(process.env.P2BOT_HOME || path.join(os.homedir(), 'p2bot'), task, 'bin', 'p2bot')
  let body
  try { body = fs.readFileSync(file, 'utf8') } catch { return { ok: false, error: 'this task has no folder on this Mac' } }
  if (!/^P2BOT_SERVER=\S+ P2BOT_TURN=\S+ /m.test(body)) return { ok: false, error: 'unknown bin/p2bot' }
  fs.writeFileSync(file, body.replace(/(^P2BOT_SERVER=\S+ P2BOT_TURN=)\S+/m, `$1${token}`), { mode: 0o700 })
  return { ok: true, value: null }
}

const SESSION = /^session-[0-9a-f-]{36}$/
// ponytail: a question the agent is waiting on right now lives only in the gateway's pendingRemoteEvents (no public reader or answerer;
// the same Map that backs `pendingInput`), so it is read and settled there; one that timed out is in the session's projection and has
// an API. Recheck both with each DeepSeek Harness upgrade (the plugin test fakes them).
const live = (gateway) => [...(gateway.pendingRemoteEvents?.values() ?? [])]

/** What this session's agent asks its user: open questions and approvals (live), and questions that went on without an answer. */
export async function pending({ session } = {}, gateway, peer, signal) {
  if (!SESSION.test(session || '')) return { ok: false, error: 'bad session' }
  const items = []
  for (const { frame: f } of live(gateway)) {
    if (String(f.agentId) !== session) continue
    if (f.event === 'user-questions/request') items.push({ kind: 'question', id: f.eventId, questions: f.request.questions })
    else if (f.event === 'approval/request') items.push({ kind: 'approval', id: f.eventId, tool: f.request.toolName, reason: f.request.displayReason || f.request.reason || '' })
  }
  const projected = await gateway.invoke({ namespace: 'session', method: 'projections', args: { request: { sessionId: session } }, signal, peer })
  for (const q of projected?.values?.userQuestions?.active ?? []) if (q.state === 'continued') items.push({ kind: 'question', id: q.callId, questions: q.questions })
  return { ok: true, value: items }
}

/** The user's answer: into the open request the agent waits on, else into the continued question (which steers it as a message). */
export async function answer({ session, id, value } = {}, gateway, peer, signal) {
  if (!SESSION.test(session || '') || !id) return { ok: false, error: 'bad session or id' }
  const open = live(gateway).find((p) => p.id === id && String(p.frame.agentId) === session)
  if (open) {
    if (typeof gateway.settleRemoteEvent !== 'function') return { ok: false, error: 'this DeepSeek Harness cannot take answers from here' }
    const asked = open.frame.request.questions?.map((q) => q.id).sort().join()  // same check as userQuestions.answer: each question once
    if (asked !== undefined && asked !== (value?.answers ?? []).map((a) => a.id).sort().join()) return { ok: false, error: 'the answers do not match the questions' }
    gateway.settleRemoteEvent(open, { kind: 'result', value })
    return { ok: true, value: null }
  }
  const accepted = await gateway.invoke({ namespace: 'userQuestions', method: 'answer', args: { agentId: session, callId: id, answer: value }, signal, peer })
  return accepted ? { ok: true, value: null } : { ok: false, error: 'this question is no longer waiting' }
}

/** The first frame of a stream method (a roster, a baseline): read once, then let go of the stream. */
async function first(gateway, request) {
  const stop = new AbortController()
  try {
    for await (const frame of await gateway.stream({ ...request, signal: stop.signal })) return frame
  } finally {
    stop.abort()
  }
}

/** Workspaces (the groups), their sessions in order, and the archived and pinned session ids. */
export async function workspaces(_args, gateway, peer) {
  return { ok: true, value: (await first(gateway, { namespace: 'workspace', method: 'follow', args: {}, peer })).value }
}

/** The jobs still running that this session can see, as the desktop's header counts them. */
export async function jobs({ session } = {}, gateway, peer) {
  if (!SESSION.test(session || '')) return { ok: false, error: 'bad session' }
  const frame = await first(gateway, { namespace: 'job', method: 'list', args: { request: { sessionId: session } }, peer })
  const live = (frame.jobs ?? []).filter((j) => j.status === 'running' || j.status === 'stopping')
  return { ok: true, value: live.map((j) => ({ id: j.id, kind: j.kind, label: j.label, status: j.status, at: j.startedAt, bytes: j.output?.total ?? 0 })) }
}

const LOCAL = { 'p2bot.pending': pending, 'p2bot.answer': answer, 'p2bot.workspaces': workspaces, 'p2bot.jobs': jobs }

export async function run(call, gateway, peer, signal) {
  if (!ALLOW.has(call.method)) return { ok: false, error: `not allowed: ${call.method}` }
  if (call.method === 'p2bot.token') return writeToken(call.args)
  if (LOCAL[call.method]) {
    try {
      return await LOCAL[call.method](call.args, gateway, peer, signal)
    } catch (e) {
      return { ok: false, error: String(e?.message || e).slice(0, 500), code: e?.code }
    }
  }
  const [namespace, method] = call.method.split('.')
  // a group is a folder on this Mac, which the host wants fully qualified
  if (call.method === 'workspace.create' && /^~(\/|$)/.test(call.args?.request?.path ?? '')) call.args.request.path = os.homedir() + call.args.request.path.slice(1)
  try {
    return { ok: true, value: await gateway.invoke({ namespace, method, args: call.args || {}, signal, peer }) ?? null }
  } catch (e) {
    return { ok: false, error: String(e?.message || e).slice(0, 500), code: e?.code }
  }
}

export function apply(ctx) {
  const gateway = ctx.get('typertGateway')
  // every Gateway call names the Peer it speaks for; this host's own UI speaks as the owner through Connection's browser Peer
  const peer = () => ctx.get('connection')?.browserPeer
  ctx.effect(() => {
    const stop = new AbortController()
    const post = async (route, body) => {
      const { server, token } = settings()
      const res = await fetch(server + route, {
        method: 'POST', signal: stop.signal, body: JSON.stringify(body),
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-P2B-Bridge': name },
      })
      if (!res.ok) throw new Error(`${route} ${res.status}`)
      return res.json()
    }
    ;(async () => {
      while (!stop.signal.aborted) {
        try {
          const { calls = [] } = await post('/api/runner/dsh/poll', { wait: 25, host: os.hostname().split('.')[0] })
          for (const call of calls) {
            run(call, gateway, peer(), stop.signal).then((r) => post('/api/runner/dsh/reply', { id: call.id, ...r })).catch(() => {})
          }
        } catch (e) {
          if (stop.signal.aborted) break
          ctx.logger?.('p2bot-bridge')?.warn?.(String(e?.message || e))
          await new Promise((r) => setTimeout(r, 10_000))  // server away (restart, network): try again shortly
        }
      }
    })()
    return () => stop.abort()
  }, 'p2bot bridge')
}
