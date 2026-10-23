// @oplayer {"api":4,"id":"site.disable-devtool","name":"disable-devtool 차단","version":"1.1.0","kind":"browser","capabilities":["page","blockRequests"],"sites":["*"],"hosts":[],"blockRules":[{"urlFilter":"^https?://[^/?#]+/[^?#]*disable[-_.]?devtool([@/?.#_-]|$)"}],"settings":[{"key":"consoleGuard","type":"boolean","label":"콘솔 기반 개발자 도구 감지 억제","default":true}],"features":["모든 사이트·iframe 적용","disable-devtool 요청 차단","전역 API 실행 억제","콘솔 감지 완화"],"description":"모든 웹사이트에서 개발자 도구 감지로 인한 강제 이동을 억제합니다. 다른 코드에 합쳐진 변형은 일부만 대응합니다."}

globalThis.plugin = {
  page(api) {
    if (window.__oplayerDisableDevtoolGuard) return;
    window.__oplayerDisableDevtoolGuard = true;

    // A callable facade keeps the site's initialization checks working while
    // preventing the public library entry point from installing its detectors.
    const disabled = Object.assign(function () {
      return {success: true, reason: 'disabled by OPlayer extension'};
    }, {
      isRunning: false,
      isSuspend: true,
      isDevToolOpened: () => false,
      DetectorType: Object.freeze({}),
    });
    for (const name of ['DisableDevtool', 'disableDevtool']) {
      try {
        const current = window[name];
        if (typeof current === 'function') {
          try { current.isSuspend = true; } catch (_) {}
        }
        Object.defineProperty(window, name, {
          configurable: true,
          get: () => disabled,
          set(value) {
            // Support a late UMD assignment without restoring active detectors.
            if (typeof value === 'function') {
              try { value.isSuspend = true; } catch (_) {}
            }
          },
        });
      } catch (_) {
        // Non-configurable properties cannot be replaced by a page extension.
      }
    }

    if (api.config.consoleGuard !== false && window.console) {
      // Bundled variants cache console functions to inspect getters/toString
      // and benchmark log/table. Keep warn/error for actual page errors.
      for (const name of ['log', 'debug', 'info', 'dir', 'dirxml', 'table', 'clear']) {
        try { window.console[name] = function () {}; } catch (_) {}
      }
    }
  },
};
