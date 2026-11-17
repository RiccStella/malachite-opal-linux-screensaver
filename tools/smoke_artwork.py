"""Real sandboxed Chromium smoke check for local-file artwork (CI/desktop)."""
from pathlib import Path
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parents[1]
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(channel='chrome', headless=True, chromium_sandbox=True)
    page = browser.new_page(viewport={'width': 800, 'height': 600})
    errors, remote_requests = [], []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.on('request', lambda request: remote_requests.append(request.url) if request.url.startswith(('https:', 'http:')) else None)
    # Count actual shader draws to verify animation rather than just a loaded DOM.
    page.add_init_script('''window.testDraws = 0;
const original = WebGLRenderingContext.prototype.drawArrays;
WebGLRenderingContext.prototype.drawArrays = function(...args) {
  window.testDraws++; return original.apply(this, args);
};''')
    page.goto((root / 'artwork/index.html').as_uri())
    page.wait_for_function('window.testDraws > 5', timeout=15000)
    assert page.title() == 'Malachite Opal'
    assert not errors, errors
    assert not remote_requests, remote_requests
    print('PASS: file:// artwork animates in sandboxed Chromium; no HTTP(S) resource requests.')
    browser.close()
