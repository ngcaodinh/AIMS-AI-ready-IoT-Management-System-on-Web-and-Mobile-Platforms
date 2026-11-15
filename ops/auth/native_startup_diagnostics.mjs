/** Redacted receipt observations, never a causal diagnosis or an admission/terminal oracle. */
export function createNativeStartupDiagnostics(now = performance.now.bind(performance)) {
  const origin = now(); const tags = new Set();
  const receiptMs = { appStart: null, appStarted: null, rawMarker: null, ownedMarker: null, appStop: null, sdkExit: null };
  let sdkExitKind = 'NOT_OBSERVED'; let stopErrorField = 'NOT_OBSERVED'; let sdkPipesClosed = false; let stderrTail = '';
  const marker = 'NATIVE_AUTH_TEST_CHANNEL_READY';

  function receipt(key) {
    if (receiptMs[key] !== null) return;
    const elapsed = now() - origin;
    if (Number.isFinite(elapsed) && elapsed >= 0) receiptMs[key] = Math.floor(elapsed);
    else tags.add('CLOCK_INVALID');
  }

  function classify(text) {
    if (typeof text !== 'string' || !text) return;
    if (text.length > 4096) { tags.add('OVERSIZED_LOG'); return; }
    const patterns = [
      ['DEVFS_FAILURE', /Error initializing DevFS|DevFSException|Failed to[^\n]*DevFS/i],
      ['SERVICE_CONNECTION_FAILURE', /Error connecting to the service protocol|ServiceDisappeared|Failed to connect to[^\n]*service/i],
      ['APP_FAILED_TO_START', /App failed to start|Error launching application/i],
      ['DEVICE_CONNECTION_LOST', /Lost connection to device|device[^\n]*(?:offline|not found)/i],
      ['BUILD_FAILURE', /FAILURE: Build failed|Gradle task[^\n]*failed/i],
      ['SIXTY_SECOND_TIMEOUT', /TimeoutException after 0:01:00/i],
      ['FRAMEWORK_FAILURE', /Some tests failed|Test failed|EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK/i],
    ];
    let matched = false;
    for (const [tag, pattern] of patterns) if (pattern.test(text)) { tags.add(tag); matched = true; }
    if (!matched) tags.add('OTHER_LOG');
  }

  return Object.freeze({
    rawLine: (line) => {
      if (typeof line !== 'string') return;
      if (line.includes(marker)) receipt('rawMarker');
      // JSON app logs are classified only after matching their validated owner below.
      if (!line.startsWith('[{')) classify(line);
    },
    stderr: (text) => {
      if (typeof text !== 'string') return;
      classify(stderrTail + text); stderrTail = (stderrTail + text).slice(-256);
    },
    message: (message, ownedAppId) => {
      if (message?.event === 'daemon.logMessage') { classify(message.params?.message); return; }
      if (!ownedAppId || message?.params?.appId !== ownedAppId) return;
      if (message.event === 'app.start') receipt('appStart');
      else if (message.event === 'app.started') receipt('appStarted');
      else if (message.event === 'app.stop') {
        receipt('appStop');
        stopErrorField = Object.hasOwn(message.params, 'error') && message.params.error != null ? 'PRESENT' : 'ABSENT';
        if (typeof message.params.error === 'string') classify(message.params.error);
      } else if (message.event === 'app.log' && typeof message.params.log === 'string') {
        if (message.params.log.endsWith(marker)) receipt('ownedMarker');
        classify(message.params.log);
      }
    },
    exit: (code, signal) => {
      receipt('sdkExit');
      sdkExitKind = Number.isInteger(code) ? ([0, 1, 2, 3].includes(code) ? `CODE_${code}` : 'OTHER_CODE') : signal ? 'SIGNAL' : 'NOT_OBSERVED';
    },
    pipesClosed: () => { sdkPipesClosed = true; },
    snapshot: () => ({ sdkExitKind, sdkPipesClosed, stopErrorField, rawMarkerSeen: receiptMs.rawMarker !== null,
      ownedMarkerSeen: receiptMs.ownedMarker !== null, receiptMs: { ...receiptMs }, tags: [...tags].sort() }),
    clear: () => { stderrTail = ''; },
  });
}
