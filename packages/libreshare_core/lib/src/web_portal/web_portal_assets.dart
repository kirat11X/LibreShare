/// Built-in HTML5/CSS/JS assets for the LibreShare Web Portal single-page app.
class WebPortalAssets {
  WebPortalAssets._();

  /// Self-contained responsive HTML5 web portal single page application.
  static const String indexHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="LibreShare">
  <meta name="theme-color" content="#0f172a">
  <link rel="manifest" href="/web/manifest.json">
  <title>LibreShare Web Portal</title>
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --card-hover: #273549;
      --border: #334155;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --primary: #3b82f6;
      --primary-hover: #2563eb;
      --success: #10b981;
      --danger: #ef4444;
      --radius: 12px;
    }
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    body {
      background-color: var(--bg);
      color: var(--text);
      min-height: 100vh;
      padding: 24px 16px;
      display: flex;
      flex-direction: column;
      align-items: center;
    }
    .container {
      width: 100%;
      max-width: 720px;
      display: flex;
      flex-direction: column;
      gap: 20px;
    }
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 16px 20px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: var(--radius);
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .brand-icon {
      width: 32px;
      height: 32px;
      color: var(--primary);
    }
    h1 {
      font-size: 1.25rem;
      font-weight: 700;
    }
    .device-info {
      font-size: 0.85rem;
      color: var(--text-muted);
      margin-top: 2px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 9999px;
      font-size: 0.75rem;
      font-weight: 600;
      background: rgba(16, 185, 129, 0.15);
      color: var(--success);
    }
    .badge-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--success);
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 20px;
    }
    .card-title {
      font-size: 1.1rem;
      font-weight: 600;
      margin-bottom: 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      padding: 8px 16px;
      background: var(--primary);
      color: #ffffff;
      border: none;
      border-radius: 8px;
      font-size: 0.9rem;
      font-weight: 600;
      cursor: pointer;
      text-decoration: none;
      transition: background 0.15s ease;
    }
    .btn:hover {
      background: var(--primary-hover);
    }
    .btn-secondary {
      background: var(--border);
      color: var(--text);
    }
    .btn-secondary:hover {
      background: #475569;
    }
    .file-list {
      list-style: none;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .file-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 12px 16px;
      background: rgba(15, 23, 42, 0.6);
      border: 1px solid var(--border);
      border-radius: 8px;
      transition: background 0.15s ease;
    }
    .file-item:hover {
      background: var(--card-hover);
    }
    .file-details {
      display: flex;
      align-items: center;
      gap: 12px;
      overflow: hidden;
    }
    .file-icon {
      width: 24px;
      height: 24px;
      color: var(--primary);
      flex-shrink: 0;
    }
    .file-meta {
      overflow: hidden;
    }
    .file-name {
      font-size: 0.95rem;
      font-weight: 500;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .file-size {
      font-size: 0.8rem;
      color: var(--text-muted);
      margin-top: 2px;
    }
    .empty-state {
      text-align: center;
      padding: 36px 16px;
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .dropzone {
      border: 2px dashed var(--border);
      border-radius: var(--radius);
      padding: 32px 16px;
      text-align: center;
      cursor: pointer;
      transition: border-color 0.15s ease, background 0.15s ease;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 12px;
    }
    .dropzone.dragover {
      border-color: var(--primary);
      background: rgba(59, 130, 246, 0.05);
    }
    .dropzone-icon {
      width: 40px;
      height: 40px;
      color: var(--text-muted);
    }
    .progress-wrap {
      display: none;
      margin-top: 16px;
    }
    .progress-bar-bg {
      width: 100%;
      height: 8px;
      background: var(--border);
      border-radius: 9999px;
      overflow: hidden;
    }
    .progress-bar-fill {
      height: 100%;
      width: 0%;
      background: var(--primary);
      transition: width 0.2s ease;
    }
    .progress-status {
      display: flex;
      justify-content: space-between;
      font-size: 0.8rem;
      color: var(--text-muted);
      margin-top: 6px;
    }
    .alert {
      padding: 10px 14px;
      border-radius: 8px;
      font-size: 0.85rem;
      margin-top: 12px;
      display: none;
    }
    .alert-danger {
      background: rgba(239, 68, 68, 0.15);
      color: #fca5a5;
      border: 1px solid var(--danger);
    }
    .alert-success {
      background: rgba(16, 185, 129, 0.15);
      color: #6ee7b7;
      border: 1px solid var(--success);
    }
    .pin-card {
      text-align: center;
    }
    .pin-input {
      width: 100%;
      max-width: 240px;
      padding: 12px;
      font-size: 1.2rem;
      text-align: center;
      letter-spacing: 4px;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text);
      margin: 16px 0;
      outline: none;
    }
    .pin-input:focus {
      border-color: var(--primary);
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="brand">
        <svg class="brand-icon" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
        </svg>
        <div>
          <h1>LibreShare</h1>
          <div class="device-info" id="deviceName">Local Web Portal</div>
        </div>
      </div>
      <div style="display: flex; align-items: center; gap: 8px;">
        <button id="installAppBtn" class="btn btn-secondary" style="padding: 6px 12px; font-size: 0.8rem; display: none;" onclick="installPwa()">📲 Install App</button>
        <div class="badge">
          <div class="badge-dot"></div>
          <span>Connected</span>
        </div>
      </div>
    </header>

    <div id="pinPrompt" class="card pin-card" style="display: none;">
      <h2 style="font-size: 1.2rem; margin-bottom: 8px;">Access PIN Required</h2>
      <p style="color: var(--text-muted); font-size: 0.9rem;">This device is protected by a PIN code.</p>
      <input type="password" id="pinCode" class="pin-input" placeholder="••••" autocomplete="off" />
      <br>
      <button class="btn" id="pinSubmitBtn" onclick="submitPin()">Unlock</button>
      <div id="pinAlert" class="alert alert-danger"></div>
    </div>

    <div id="mainSection" style="display: flex; flex-direction: column; gap: 20px;">
      <div class="card">
        <div class="card-title">
          <span>Available Shared Files</span>
          <button class="btn btn-secondary" style="padding: 4px 10px; font-size: 0.8rem;" onclick="loadFiles()">Refresh</button>
        </div>
        <ul id="filesList" class="file-list"></ul>
        <div id="emptyFiles" class="empty-state" style="display: none;">No files currently shared.</div>
      </div>

      <div class="card">
        <div class="card-title">
          <span>Send Files to Device</span>
        </div>
        <div id="dropzone" class="dropzone" onclick="document.getElementById('fileInput').click()">
          <svg class="dropzone-icon" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
          </svg>
          <div style="font-weight: 500;">Drop files here or click to select</div>
          <div style="font-size: 0.8rem; color: var(--text-muted);">Transfer directly over local Wi-Fi</div>
          <input type="file" id="fileInput" multiple style="display: none;" onchange="handleFileSelect(this.files)" />
        </div>

        <div id="uploadProgress" class="progress-wrap">
          <div class="progress-bar-bg">
            <div id="progressFill" class="progress-bar-fill"></div>
          </div>
          <div class="progress-status">
            <span id="uploadFileName">Uploading...</span>
            <span id="uploadPercent">0%</span>
          </div>
        </div>

        <div id="uploadAlert" class="alert"></div>
      </div>
    </div>
  </div>

  <script>
    let authToken = sessionStorage.getItem('ls_web_token') || '';
    let pinRequired = false;

    function formatBytes(bytes) {
      if (bytes === 0) return '0 B';
      const k = 1024;
      const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
    }

    async function init() {
      try {
        const res = await fetch('/web/api/info');
        if (!res.ok) throw new Error('Failed to load device info');
        const info = await res.json();
        document.getElementById('deviceName').textContent = info.deviceName + ' (v' + info.version + ')';
        pinRequired = info.pinRequired;

        if (pinRequired && !authToken) {
          showPinPrompt();
        } else {
          showMainSection();
          loadFiles();
        }
      } catch (err) {
        console.error(err);
      }
    }

    function showPinPrompt() {
      document.getElementById('pinPrompt').style.display = 'block';
      document.getElementById('mainSection').style.display = 'none';
    }

    function showMainSection() {
      document.getElementById('pinPrompt').style.display = 'none';
      document.getElementById('mainSection').style.display = 'flex';
    }

    async function submitPin() {
      const pin = document.getElementById('pinCode').value;
      const alertBox = document.getElementById('pinAlert');
      alertBox.style.display = 'none';

      try {
        const res = await fetch('/web/api/auth', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ pin: pin })
        });
        if (res.status === 429) {
          alertBox.textContent = 'Too many attempts. Please try again later.';
          alertBox.style.display = 'block';
          return;
        }
        if (!res.ok) {
          alertBox.textContent = 'Incorrect PIN code.';
          alertBox.style.display = 'block';
          return;
        }
        const data = await res.json();
        authToken = data.token;
        sessionStorage.setItem('ls_web_token', authToken);
        showMainSection();
        loadFiles();
      } catch (err) {
        alertBox.textContent = 'Network error. Try again.';
        alertBox.style.display = 'block';
      }
    }

    async function loadFiles() {
      const headers = {};
      if (authToken) headers['Authorization'] = 'Bearer ' + authToken;

      try {
        const res = await fetch('/web/api/files', { headers });
        if (res.status === 401) {
          showPinPrompt();
          return;
        }
        const files = await res.json();
        const list = document.getElementById('filesList');
        const empty = document.getElementById('emptyFiles');
        list.innerHTML = '';

        if (!files || files.length === 0) {
          empty.style.display = 'block';
        } else {
          empty.style.display = 'none';
          files.forEach(f => {
            const li = document.createElement('li');
            li.className = 'file-item';
            const dlUrl = '/web/download/' + encodeURIComponent(f.id) + (authToken ? '?token=' + encodeURIComponent(authToken) : '');
            li.innerHTML = `
              <div class="file-details">
                <svg class="file-icon" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M7 21h10a2 2 0 002-2V9.414a1 1 0 00-.293-.707l-5.414-5.414A1 1 0 0012.586 3H7a2 2 0 00-2 2v14a2 2 0 002 2z" />
                </svg>
                <div class="file-meta">
                  <div class="file-name" title="${f.name}">${f.name}</div>
                  <div class="file-size">${formatBytes(f.size)}</div>
                </div>
              </div>
              <a href="${dlUrl}" download="${f.name}" class="btn" style="padding: 6px 12px; font-size: 0.85rem;">Download</a>
            `;
            list.appendChild(li);
          });
        }
      } catch (err) {
        console.error('Error fetching files', err);
      }
    }

    function handleFileSelect(files) {
      if (!files || files.length === 0) return;
      uploadQueue(Array.from(files));
    }

    async function uploadQueue(files) {
      const progressWrap = document.getElementById('uploadProgress');
      const progressFill = document.getElementById('progressFill');
      const uploadFileName = document.getElementById('uploadFileName');
      const uploadPercent = document.getElementById('uploadPercent');
      const alertBox = document.getElementById('uploadAlert');
      alertBox.style.display = 'none';
      progressWrap.style.display = 'block';

      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        uploadFileName.textContent = `Uploading ${file.name} (${i + 1}/${files.length})...`;
        progressFill.style.width = '0%';
        uploadPercent.textContent = '0%';

        await new Promise((resolve) => {
          const xhr = new XMLHttpRequest();
          xhr.open('POST', '/web/api/upload');
          xhr.setRequestHeader('X-Filename', file.name);
          if (authToken) {
            xhr.setRequestHeader('Authorization', 'Bearer ' + authToken);
          }

          xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) {
              const pct = Math.round((e.loaded / e.total) * 100);
              progressFill.style.width = pct + '%';
              uploadPercent.textContent = pct + '%';
            }
          };

          xhr.onload = () => {
            if (xhr.status === 200) {
              resolve();
            } else {
              alertBox.className = 'alert alert-danger';
              alertBox.textContent = `Upload failed for ${file.name} (status ${xhr.status})`;
              alertBox.style.display = 'block';
              resolve();
            }
          };

          xhr.onerror = () => {
            alertBox.className = 'alert alert-danger';
            alertBox.textContent = `Network error uploading ${file.name}`;
            alertBox.style.display = 'block';
            resolve();
          };

          xhr.send(file);
        });
      }

      progressWrap.style.display = 'none';
      alertBox.className = 'alert alert-success';
      alertBox.textContent = 'Files uploaded successfully!';
      alertBox.style.display = 'block';
      setTimeout(() => { alertBox.style.display = 'none'; }, 4000);
      loadFiles();
    }

    const dropzone = document.getElementById('dropzone');
    ['dragenter', 'dragover'].forEach(eventName => {
      dropzone.addEventListener(eventName, (e) => {
        e.preventDefault();
        dropzone.classList.add('dragover');
      }, false);
    });
    ['dragleave', 'drop'].forEach(eventName => {
      dropzone.addEventListener(eventName, (e) => {
        e.preventDefault();
        dropzone.classList.remove('dragover');
      }, false);
    });
    dropzone.addEventListener('drop', (e) => {
      const dt = e.dataTransfer;
      if (dt && dt.files && dt.files.length) {
        handleFileSelect(dt.files);
      }
    });

    let deferredPrompt = null;
    window.addEventListener('beforeinstallprompt', (e) => {
      e.preventDefault();
      deferredPrompt = e;
      const btn = document.getElementById('installAppBtn');
      if (btn) btn.style.display = 'inline-flex';
    });

    function installPwa() {
      if (deferredPrompt) {
        deferredPrompt.prompt();
        deferredPrompt.userChoice.then((choiceResult) => {
          if (choiceResult.outcome === 'accepted') {
            const btn = document.getElementById('installAppBtn');
            if (btn) btn.style.display = 'none';
          }
          deferredPrompt = null;
        });
      } else {
        const isIos = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
        if (isIos) {
          alert("To install LibreShare on your device:\n1. Tap the Share button in Safari (box with up arrow)\n2. Scroll down and tap 'Add to Home Screen'");
        } else {
          alert("To install, use your browser's menu (⋮) and tap 'Install app' or 'Add to Home screen'.");
        }
      }
    }

    // Show install button for iOS if not already in standalone mode
    window.addEventListener('DOMContentLoaded', () => {
      const isIos = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
      const isStandalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone;
      if (isIos && !isStandalone) {
        const btn = document.getElementById('installAppBtn');
        if (btn) btn.style.display = 'inline-flex';
      }
    });

    window.addEventListener('DOMContentLoaded', init);
  </script>
</body>
</html>
''';
}
