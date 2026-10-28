'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { redactSecrets, filterLaunchctlOutput, handleCommand, handleRecover } = require('./recovery.cjs');

const now = 1800000000000;
function recover(overrides = {}, targetOverrides = {}) {
  const submitted = [];
  const input = { targetKey: 'agent:com.homelab.ompweb', action: 'restore', approvedAt: new Date(now).toISOString(), ...overrides };
  const dependencies = {
    now: () => now,
    readMaintenance: () => ({ active: false }),
    collectTargets: () => [{ key: input.targetKey, actionable: true, action: 'restore', display: 'Fixture', ...targetOverrides }],
    scheduleRestartWorker: (...args) => { submitted.push(args); return { ok: true, data: { jobId: 'a'.repeat(32), phase: 'queued' } }; },
  };
  return { result: handleRecover(input, dependencies), submitted };
}

test('unknown commands cannot introduce shell command authority', () => {
  assert.equal(handleCommand({ command: 'execute_approved_recovery', shell: 'echo denied' }).ok, false);
});

test('invalid target syntax is rejected before submission', () => {
  const { result, submitted } = recover({ targetKey: 'agent:fixture;echo INJECTED' });
  assert.equal(result.ok, false);
  assert.deepEqual(submitted, []);
});

test('expired and future approvals cannot submit recovery', () => {
  for (const offset of [-61000, 3600000]) {
    const { result, submitted } = recover({ approvedAt: new Date(now + offset).toISOString() });
    assert.equal(result.ok, false);
    assert.deepEqual(submitted, []);
  }
});

test('native recovery requires an explicit approved effect', () => {
  for (const action of [undefined, '', 'delete', 1]) {
    const { result, submitted } = recover({ action });
    assert.equal(result.ok, false);
    assert.deepEqual(submitted, []);
  }
});

test('changed approved effect is rejected without submission', () => {
  const { result, submitted } = recover({ action: 'restart' });
  assert.equal(result.ok, false);
  assert.match(result.error, /onaylanan işlem/);
  assert.deepEqual(submitted, []);
});

test('native approval effect and absolute expiry reach queue admission', () => {
  const { result, submitted } = recover();
  assert.equal(result.ok, true);
  assert.equal(submitted.length, 1);
  assert.equal(submitted[0][3].approvedAction, 'restore');
  assert.equal(submitted[0][3].approvalExpiresAt, now + 60000);
});

test('protected access requires actual independent-access user attestation', () => {
  for (const independentAccess of [undefined, false, 'true']) {
    const { result, submitted } = recover({ independentAccess }, { highRisk: true });
    assert.equal(result.ok, false);
    assert.deepEqual(submitted, []);
  }
  assert.equal(recover({ independentAccess: true }, { highRisk: true }).result.ok, true);
});

test('job lookup rejects path traversal', () => {
  assert.equal(handleCommand({ command: 'job', id: '../../etc/passwd' }).ok, false);
});

test('redactor removes every private-key envelope including PKCS8 and JSON escapes', () => {
  for (const prefix of ['', 'RSA ', 'EC ', 'OPENSSH ', 'ENCRYPTED ']) {
    const key = `-----BEGIN ${prefix}PRIVATE KEY-----\nSYNTHETIC-KEY-MATERIAL\n-----END ${prefix}PRIVATE KEY-----`;
    for (const input of [key, JSON.stringify({ message: key }), JSON.stringify(JSON.stringify({ message: key }))]) {
      const result = redactSecrets(input);
      assert.ok(result.includes('[REDACTED PRIVATE KEY]'));
      assert.ok(!result.includes('SYNTHETIC-KEY-MATERIAL'));
      assert.ok(!result.includes('-----BEGIN'));
    }
  }
});

test('redactor handles escaped JSON credentials without leaking value suffixes', () => {
  const input = JSON.stringify({ api_key: 'SYNTHETIC-ONE"secret', password: 'SYNTHETIC-TWO\\tail', message: 'safe text' });
  const output = redactSecrets(input);
  assert.ok(!output.includes('SYNTHETIC-ONE'));
  assert.ok(!output.includes('secret'));
  assert.ok(!output.includes('SYNTHETIC-TWO'));
  assert.ok(!output.includes('tail'));
  assert.ok(output.includes('safe text'));
});

test('launchctl environment blocks and arrow credentials are excluded', () => {
  const output = redactSecrets(filterLaunchctlOutput('service {\n environment = {\n TOKEN => SYNTHETIC-ENV\n }\n API_KEY => SYNTHETIC-ARROW\n state = running\n}'));
  assert.ok(!output.includes('SYNTHETIC-ENV'));
  assert.ok(!output.includes('SYNTHETIC-ARROW'));
  assert.ok(output.includes('state = running'));
});
