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
  'session.modelCatalog', 'session.selectModel', 'session.rename', 'p2bot.token',
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

export async function run(call, gateway, peer, signal) {
  if (!ALLOW.has(call.method)) return { ok: false, error: `not allowed: ${call.method}` }
  if (call.method === 'p2bot.token') return writeToken(call.args)
  const [namespace, method] = call.method.split('.')
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
