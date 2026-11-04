// node --test dsh-plugin/test.mjs: the plugin runs only the allowed calls, as the owner, and reports failures instead of throwing
import assert from 'node:assert/strict'
import test from 'node:test'
import { run, ALLOW } from './index.js'

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
