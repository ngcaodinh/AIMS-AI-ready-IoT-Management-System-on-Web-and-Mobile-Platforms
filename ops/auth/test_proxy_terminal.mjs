import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createCertificates } from './memory_tls_material.mjs';

/** Real proxy owner with only the TLS server/timer boundary substituted; no network/DB/SDK. */
function boundary() {
  const server = new EventEmitter();
  const socket = new EventEmitter(); socket.closed = false; socket.destroy = () => { socket.destroyRequested = true; };
  let listenerClose;
  const timers = new Set();
  server.listen = () => { server.listening = true; queueMicrotask(() => server.emit('listening')); };
  server.address = () => ({ port: 12345 });
  server.close = (callback) => { listenerClose = callback; };
  return { server, socket, timers,
    releaseListener: () => { server.listening = false; listenerClose(); },
    releaseSocket: () => { socket.closed = true; socket.emit('close'); },
    runtime: { createServer: () => server,
      setTimeout: (callback, milliseconds) => { const timer = { callback, milliseconds }; timers.add(timer); return timer; },
      clearTimeout: (timer) => timers.delete(timer) },
  };
}

async function turns() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

const certificates = createCertificates();
try {
  for (const order of ['socket-first', 'listener-first', 'listener-error', 'lifetime']) {
    const test = boundary(); let proxy;
    try {
      proxy = await startLocalHttpsProxy(certificates.valid, { port: 0 }, undefined, test.runtime);
      assert.ok(proxy.signal instanceof AbortSignal, 'MISSING_UNAVAILABLE_SIGNAL');
      assert.ok(proxy.terminal instanceof Promise, 'MISSING_RAW_TERMINAL');
      assert.equal(proxy.signal.aborted, false);
      test.server.emit('connection', test.socket);
      let terminal = false; proxy.terminal.then(() => { terminal = true; });
      if (order === 'listener-error') test.server.emit('error', new Error('PRIVATE_LISTENER_SENTINEL'));
      if (order === 'lifetime') [...test.timers].find((timer) => timer.milliseconds === 3_000_000).callback();
      const first = proxy.close();
      assert.equal(proxy.close(), first); assert.equal(first, proxy.closed);
      assert.equal(proxy.signal.aborted, true); assert.equal(test.socket.destroyRequested, true);
      [...test.timers].find((timer) => timer.milliseconds === 5000).callback();
      assert.equal(await first, false); await turns(); assert.equal(terminal, false);
      if (order === 'listener-first') test.releaseListener(); else test.releaseSocket();
      await turns(); assert.equal(terminal, false);
      if (order === 'listener-first') test.releaseSocket(); else test.releaseListener();
      await proxy.terminal; assert.equal(terminal, true);
      assert.equal(await proxy.closed, false); assert.equal(test.timers.size, 0);
    } finally {
      if (proxy) {
        if (test.socket.destroyRequested) { test.releaseSocket(); test.releaseListener(); }
        await proxy.close(); await proxy.terminal;
      }
    }
  }
  console.log('PROXY_RAW_TERMINAL_AFTER_BOUNDED_FAILURE_PASS');
  for (const mode of ['spontaneous-close', 'error-not-listening', 'bind-handoff']) {
    const test = boundary(); let owned; let settled = false;
    if (mode === 'bind-handoff') test.server.listen = () => queueMicrotask(() => {
      test.server.listening = true; test.server.emit('listening');
      test.server.listening = false; test.server.emit('error', new Error('PRIVATE_BIND_SENTINEL'));
    });
    const operation = startLocalHttpsProxy(certificates.valid, { port: 0 }, undefined,
      { ...test.runtime, onOwned: (owner) => { owned = owner; } });
    operation.then(() => { settled = true; }, () => { settled = true; });
    if (mode === 'bind-handoff') {
      await turns(); assert.ok(owned); assert.equal(owned.signal.aborted, true); assert.equal(settled, false);
      test.releaseListener(); await assert.rejects(() => operation); await owned.terminal;
    } else {
      const proxy = await operation; assert.equal(proxy, owned);
      test.server.listening = false;
      if (mode === 'spontaneous-close') test.server.emit('close');
      else test.server.emit('error', new Error('PRIVATE_LISTENER_SENTINEL'));
      assert.equal(proxy.signal.aborted, true);
      if (mode !== 'spontaneous-close') test.releaseListener();
      assert.equal(await proxy.close(), false); await proxy.terminal;
    }
    assert.equal(test.timers.size, 0);
  }
  console.log('PROXY_SPONTANEOUS_CLOSE_BIND_HANDOFF_OWNERSHIP_PASS');
} finally { for (const value of Object.values(certificates)) value.pfx.fill(0); }
