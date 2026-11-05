// node --test dsh-plugin/test.mjs: the plugin runs only the allowed calls, as the owner, and reports failures instead of throwing
import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { run, ALLOW, writeToken } from './index.js'

const S = 'session-11111111-1111-1111-1111-111111111111'

test('only the allowed calls reach the host, with the peer and named args', async () => {
  const seen = []
  const gateway = { invoke: async (r) => { seen.push(r); if (r.method === 'cancel') throw Object.assign(new Error('busy'), { code: 'session/x' }); return { items: [] } } }
  const peer = { principal: { kind: 'owner' } }
  assert.deepEqual(await run({ method: 'session.list', args: { _request: {} } }, gateway, peer), { ok: true, value: { items: [] } })
  assert.deepEqual(seen[0], { namespace: 'session', method: 'list', args: { _request: {} }, signal: undefined, peer })
  assert.deepEqual(await run({ method: 'session.cancel', args: {} }, gateway, peer), { ok: false, error: 'busy', code: 'session/x' })
  assert.equal((await run({ method: 'settings.update', args: {} }, gateway, peer)).ok, false)
  assert.equal(seen.length, 2)
  assert.ok(!ALLOW.has('credentials.set') && !ALLOW.has('settings.update'))
})

test('a turn token goes into that task\'s bin/p2bot only, replacing just the token', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'p2bot-'))
  process.env.P2BOT_HOME = home
  const bin = path.join(home, 'abcdef0123456789', 'bin')
  fs.mkdirSync(bin, { recursive: true })
  fs.writeFileSync(path.join(bin, 'p2bot'), "#!/bin/sh\nP2BOT_SERVER=https://x P2BOT_TURN=old.bt-1.s PYTHONPATH=/r exec python3 -m p2b_client.bot \"$@\"\n")
  const token = 'lib.bt-' + 'a'.repeat(32) + '.secret-_x'
  assert.deepEqual(writeToken({ task: 'abcdef0123456789', token }), { ok: true, value: null })
  assert.equal(fs.readFileSync(path.join(bin, 'p2bot'), 'utf8').split('\n')[1], `P2BOT_SERVER=https://x P2BOT_TURN=${token} PYTHONPATH=/r exec python3 -m p2b_client.bot "$@"`)
  assert.equal(writeToken({ task: '../../etc/passwdx', token }).ok, false)
  assert.equal(writeToken({ task: 'abcdef0123456789', token: 'x; rm -rf ~' + 'a'.repeat(20) }).ok, false)
  assert.equal(writeToken({ task: '0000000000000000', token }).ok, false)  // no folder: the server lets the runner do the turn
})

test('what the agent asks is read from the open requests and the projection, and answered where it waits', async () => {
  const ev = (eventId, event, request, agentId = S) => ({ id: eventId, frame: { eventId, event, agentId, request } })
  const questions = [{ id: 'a', question: '选哪个？', options: [{ label: 'x' }] }]
  const settled = []
  const gateway = {
    pendingRemoteEvents: new Map([['e1', ev('e1', 'user-questions/request', { questions })], ['e2', ev('e2', 'approval/request', { toolName: 'bash', reason: 'rm' })],
      ['e3', ev('e3', 'approval/request', { toolName: 'other' }, 'session-22222222-2222-2222-2222-222222222222')]]),
    settleRemoteEvent: (p, outcome) => settled.push([p.id, outcome]),
    invoke: async (r) => (r.namespace === 'session'
      ? { values: { userQuestions: { active: [{ callId: 'c1', state: 'continued', questions }, { callId: 'c2', state: 'open', questions }] } } }
      : (r.args.callId === 'c1')),
  }
  const items = (await run({ method: 'p2bot.pending', args: { session: S } }, gateway, {})).value
  assert.deepEqual(items.map((i) => [i.kind, i.id]), [['question', 'e1'], ['approval', 'e2'], ['question', 'c1']])  // not the other session's, not the one still open in the projection
  assert.equal((await run({ method: 'p2bot.pending', args: { session: '../x' } }, gateway, {})).ok, false)
  const mine = { answers: [{ id: 'a', selected: ['x'] }] }
  assert.equal((await run({ method: 'p2bot.answer', args: { session: S, id: 'e1', value: { answers: [{ id: 'zzz', selected: [] }] } } }, gateway, {})).ok, false)
  assert.equal((await run({ method: 'p2bot.answer', args: { session: S, id: 'e1', value: mine } }, gateway, {})).ok, true)
  assert.equal((await run({ method: 'p2bot.answer', args: { session: S, id: 'e2', value: 'allowed-once' } }, gateway, {})).ok, true)
  assert.deepEqual(settled, [['e1', { kind: 'result', value: mine }], ['e2', { kind: 'result', value: 'allowed-once' }]])
  assert.equal((await run({ method: 'p2bot.answer', args: { session: S, id: 'c1', value: mine } }, gateway, {})).ok, true)  // continued: through the API
  assert.equal((await run({ method: 'p2bot.answer', args: { session: S, id: 'gone', value: mine } }, gateway, {})).ok, false)
})
