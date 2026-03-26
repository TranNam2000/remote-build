require('dotenv').config({ path: require('path').join(__dirname, '../.env') });
const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const cors = require('cors');

const app = express();
const PORT = 3000;

const SERVER_LOG = path.join(__dirname, '../server.log');
const SERVER_ERR_LOG = path.join(__dirname, '../server-err.log');

function writeServerLog(level, ...args) {
    const ts = new Date().toLocaleString('vi-VN');
    const msg = args.map(a => (a instanceof Error ? a.stack || a.message : (typeof a === 'string' ? a : JSON.stringify(a)))).join(' ');
    const line = `[${ts}] [${level}] ${msg}\n`;
    const file = (level === 'ERROR' || level === 'CRITICAL') ? SERVER_ERR_LOG : SERVER_LOG;
    try { fs.appendFileSync(file, line); } catch(e) {}
    if (level === 'ERROR' || level === 'CRITICAL') {
        try { fs.appendFileSync(SERVER_LOG, line); } catch(e) {}
    }
}

const origLog = console.log.bind(console);
const origError = console.error.bind(console);
const origWarn = console.warn.bind(console);

console.log = (...args) => { origLog(...args); writeServerLog('INFO', ...args); };
console.error = (...args) => { origError(...args); writeServerLog('ERROR', ...args); };
console.warn = (...args) => { origWarn(...args); writeServerLog('WARN', ...args); };

process.on('uncaughtException', (err) => {
    writeServerLog('CRITICAL', 'Uncaught exception prevented server crash:', err);
    origError('🔥 [CRITICAL] Uncaught exception prevented server crash:', err);
});
process.on('unhandledRejection', (reason, promise) => {
    writeServerLog('CRITICAL', 'Unhandled rejection prevented server crash:', reason);
    origError('🔥 [CRITICAL] Unhandled rejection prevented server crash:', reason);
});

const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID || '';

// Auto-detect IP: public (VPS) → LAN → localhost
function getLanIP() {
    const nets = os.networkInterfaces();
    for (const name of Object.keys(nets)) {
        for (const net of nets[name]) {
            if (net.family === 'IPv4' && !net.internal) {
                return net.address;
            }
        }
    }
    return 'localhost';
}

async function getPublicIP() {
    const services = [
        'https://api.ipify.org',
        'https://icanhazip.com',
        'https://ifconfig.me/ip',
    ];
    for (const url of services) {
        try {
            const res = await fetch(url, {
                signal: AbortSignal.timeout(3000),
                headers: { 'Accept': 'text/plain', 'User-Agent': 'curl/7.0' }
            });
            const ip = (await res.text()).trim();
            if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) return ip;
        } catch { }
    }
    return null;
}

// Will be set after server starts
let BASE_URL = process.env.BASE_URL || `http://${getLanIP()}`;

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '../frontend'), { etag: false, maxAge: 0 }));
app.use('/builds', express.static(path.join(__dirname, '../builder/completed_builds')));

app.post('/api/set-base-url', (req, res) => {
    const { url } = req.body;
    if (!url) return res.status(400).json({ error: 'Missing url' });
    BASE_URL = url.replace(/\/+$/, '');
    console.log(`🌍 BASE_URL updated: ${BASE_URL}`);
    res.json({ success: true, baseUrl: BASE_URL });
});

// --- GitHub API helpers ---

const GITHUB_HEADERS = (token) => ({
    'Authorization': `token ${token}`,
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'Flutter-Remote-Builder'
});

async function fetchAllGitHubPages(url, token) {
    let allData = [];
    let page = 1;

    while (true) {
        const response = await fetch(`${url}${url.includes('?') ? '&' : '?'}per_page=100&page=${page}`, {
            headers: GITHUB_HEADERS(token)
        });
        if (!response.ok) throw new Error(`GitHub API error: ${response.statusText}`);
        const data = await response.json();
        if (data.length === 0) break;
        allData = allData.concat(data);
        if (data.length < 100) break;
        page++;
    }
    return allData;
}

// --- Telegram ---

function notifyTelegram(message, buttons) {
    const params = {
        chat_id: TELEGRAM_CHAT_ID,
        parse_mode: 'Markdown',
        text: message
    };
    if (buttons) {
        params.reply_markup = JSON.stringify({ inline_keyboard: buttons });
    }
    fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(params)
    }).catch(console.error);
}

// --- API Routes ---

app.post('/api/repos', async (req, res) => {
    const { token } = req.body;
    if (!token) return res.status(400).json({ error: 'Missing access token' });

    try {
        const data = await fetchAllGitHubPages(
            'https://api.github.com/user/repos?sort=updated&affiliation=owner,collaborator,organization_member',
            token
        );
        const repos = data.map(repo => ({
            name: repo.full_name,
            url: repo.clone_url,
            private: repo.private
        }));
        res.json({ repos });
    } catch (error) {
        console.error('Fetch repos error:', error.message);
        res.status(500).json({ error: error.message });
    }
});

app.post('/api/detect', async (req, res) => {
    const { repoUrl, branch, token } = req.body;
    if (!repoUrl) return res.status(400).json({ error: 'Missing repoUrl' });

    try {
        // Inject token for private repos
        let cloneUrl = repoUrl;
        if (token) {
            try {
                const urlObj = new URL(repoUrl);
                urlObj.username = 'oauth2';
                urlObj.password = token;
                cloneUrl = urlObj.toString();
            } catch { }
        }
        const { projectType, flavors } = await detectProjectType(cloneUrl, branch);
        const isMac = process.platform === 'darwin';
        const canBuildIos = isMac;

        res.json({
            projectType: projectType || 'unknown',
            flavors,
            isMac,
            canBuildIos,
            needsPlatformSelection: projectType === 'flutter' && isMac
        });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.post('/api/branches', async (req, res) => {
    const { token, repoFullName } = req.body;
    if (!token || !repoFullName) return res.status(400).json({ error: 'Missing access token or repository name' });

    try {
        const data = await fetchAllGitHubPages(
            `https://api.github.com/repos/${repoFullName}/branches`,
            token
        );
        res.json({ branches: data.map(b => b.name) });
    } catch (error) {
        console.error('Fetch branches error:', error.message);
        res.status(500).json({ error: error.message });
    }
});

// --- Project Type Detection ---

function parseFlavors(sourceDir) {
    // Search for productFlavors in build.gradle files
    const gradleFiles = [
        path.join(sourceDir, 'app/build.gradle'),
        path.join(sourceDir, 'app/build.gradle.kts'),
        path.join(sourceDir, 'android/app/build.gradle'),
        path.join(sourceDir, 'android/app/build.gradle.kts'),
    ];

    for (const gFile of gradleFiles) {
        if (!fs.existsSync(gFile)) continue;
        const content = fs.readFileSync(gFile, 'utf8');

        // Match productFlavors block — find matching closing brace by counting
        const startIdx = content.indexOf('productFlavors');
        if (startIdx === -1) continue;
        const braceStart = content.indexOf('{', startIdx);
        if (braceStart === -1) continue;
        let depth = 0;
        let braceEnd = -1;
        for (let i = braceStart; i < content.length; i++) {
            if (content[i] === '{') depth++;
            else if (content[i] === '}') { depth--; if (depth === 0) { braceEnd = i; break; } }
        }
        if (braceEnd === -1) continue;
        const match = [null, content.substring(braceStart + 1, braceEnd)];
        const block = match[1];
        // Groovy: flavorName { ... }  or  Kts: create("flavorName") { ... }
        const flavors = [];
        // Match any indented identifier followed by {
        const groovyMatches = block.matchAll(/^\s+(\w+)\s*\{/gm);
        for (const m of groovyMatches) {
            // Skip keywords that aren't flavor names
            if (!['productFlavors', 'android', 'buildTypes', 'defaultConfig', 'signingConfigs', 'compileOptions', 'kotlinOptions', 'buildFeatures', 'packaging', 'lint'].includes(m[1])) {
                flavors.push(m[1]);
            }
        }
        const ktsMatches = block.matchAll(/create\("(\w+)"\)/g);
        for (const m of ktsMatches) {
            flavors.push(m[1]);
        }

        if (flavors.length > 0) return flavors;
    }
    return [];
}

async function detectProjectType(repoUrl, branch) {
    const tempDir = path.join(os.tmpdir(), `detect_${Date.now()}`);
    try {
        // Shallow clone for fast detection
        const cloneArgs = ['clone', '--depth', '1'];
        if (branch) cloneArgs.push('--branch', branch);
        cloneArgs.push(repoUrl, 'source');

        // Ensure temp dir exists
        fs.mkdirSync(tempDir, { recursive: true });

        const cloneProc = spawn('git', cloneArgs, {
            cwd: tempDir,
            stdio: 'pipe'
        });

        await new Promise((resolve, reject) => {
            cloneProc.on('close', (code) => {
                if (code === 0) resolve();
                else reject(new Error(`Git clone failed with code ${code}`));
            });
            cloneProc.on('error', reject);
        });

        const sourceDir = path.join(tempDir, 'source');
        let projectType = null;
        let flavors = [];

        // Check for project type
        if (fs.existsSync(path.join(sourceDir, 'pubspec.yaml'))) {
            projectType = 'flutter';
        } else if (fs.existsSync(path.join(sourceDir, 'build.gradle')) ||
            fs.existsSync(path.join(sourceDir, 'build.gradle.kts')) ||
            fs.existsSync(path.join(sourceDir, 'app/build.gradle')) ||
            fs.existsSync(path.join(sourceDir, 'app/build.gradle.kts'))) {
            projectType = 'android';
        } else if (fs.existsSync(path.join(sourceDir, 'ios/Runner.xcodeproj')) ||
            fs.existsSync(path.join(sourceDir, 'ios/Runner.xcworkspace'))) {
            projectType = 'ios';
        }

        // Parse flavors for Android/Flutter projects
        if (projectType === 'flutter' || projectType === 'android') {
            flavors = parseFlavors(sourceDir);
        }

        return { projectType, flavors };
    } catch (error) {
        console.error('Detection error:', error.message);
        return { projectType: null, flavors: [] };
    } finally {
        // Cleanup temp dir
        try {
            if (process.platform === 'win32') {
                require('child_process').execSync(`rmdir /s /q "${tempDir}"`, { stdio: 'ignore' });
            } else {
                require('child_process').execSync(`rm -rf "${tempDir}"`, { stdio: 'ignore' });
            }
        } catch { }
    }
}

// --- Build System (parallel) ---

const MAX_CONCURRENT = parseInt(process.env.MAX_BUILDS) || 1;
const BUILD_TIMEOUT_MS = parseInt(process.env.BUILD_TIMEOUT_MIN || '0') * 60 * 1000;
const IDLE_TIMEOUT_MS = parseInt(process.env.BUILD_IDLE_MIN || '0') * 60 * 1000;
const buildQueue = [];
const activeBuilds = new Map(); // buildId → { job, process }
const buildLogs = new Map(); // buildId|queueId → { logs: [], listeners: Set, finished: bool, logFile: string|null }
const BUILD_LOGS_DIR = path.join(__dirname, '../builder/build_logs');
if (!fs.existsSync(BUILD_LOGS_DIR)) fs.mkdirSync(BUILD_LOGS_DIR, { recursive: true });

function getBuildLog(id) {
    if (!buildLogs.has(id)) {
        const logFile = path.join(BUILD_LOGS_DIR, `${id}.log`);
        buildLogs.set(id, { logs: [], listeners: new Set(), finished: false, logFile });
    }
    return buildLogs.get(id);
}

function emitLog(id, message, type = 'info') {
    const entry = getBuildLog(id);
    const logItem = { message, type, time: Date.now() };
    entry.logs.push(logItem);
    if (entry.logs.length > 5000) entry.logs.shift();
    for (const res of entry.listeners) {
        try {
            res.write(`data: ${JSON.stringify(logItem)}\n\n`);
            if (typeof res.flush === 'function') res.flush();
            if (typeof res.flushHeaders === 'function') res.flushHeaders();
        } catch(e) { entry.listeners.delete(res); }
    }
    const ts = new Date(logItem.time).toLocaleTimeString('vi-VN');
    try { fs.appendFileSync(entry.logFile, `[${ts}] [${type}] ${message}\n`); } catch(e) {}
}

function emitLogEnd(id) {
    const entry = getBuildLog(id);
    entry.finished = true;
    for (const res of entry.listeners) {
        try { res.write(`data: ${JSON.stringify({ type: 'end' })}\n\n`); } catch(e) {}
        try { res.end(); } catch(e) {}
    }
    entry.listeners.clear();
    try { fs.appendFileSync(entry.logFile, `\n--- BUILD FINISHED ---\n`); } catch(e) {}
    setTimeout(() => buildLogs.delete(id), 10 * 60 * 1000);
}

const startingBuilds = new Set();

function processQueue() {
    while ((activeBuilds.size + startingBuilds.size) < MAX_CONCURRENT && buildQueue.length > 0) {
        const nextIndex = buildQueue.findIndex(j => !j.paused);
        if (nextIndex === -1) break;
        const job = buildQueue.splice(nextIndex, 1)[0];
        const startId = `starting_${Date.now()}`;
        startingBuilds.add(startId);
        startBuild(job).finally(() => startingBuilds.delete(startId));
    }
    buildQueue.forEach((qJob, index) => {
        const newPos = index + 1;
        if (qJob._lastQueuePos !== newPos || qJob._lastPaused !== !!qJob.paused) {
            const status = qJob.paused ? '⏸️ Tạm dừng' : '⏳ Hàng đợi';
            qJob.sendLog(`${status}: vị trí #${newPos}/${buildQueue.length}. Đang chạy ${activeBuilds.size}/${MAX_CONCURRENT} builds.`, 'info');
            qJob._lastQueuePos = newPos;
            qJob._lastPaused = !!qJob.paused;
        }
    });
}

setInterval(() => {
    for (const [buildId, { job, process: proc }] of activeBuilds) {
        let alive = false;
        try {
            process.kill(proc.pid, 0);
            alive = true;
        } catch { }
        if (!alive) {
            console.error(`[WATCHDOG] Build process ${buildId} (pid ${proc.pid}) is dead but close event never fired. Cleaning up.`);
            job.sendLog('Build process died unexpectedly. Cleaning up...', 'error');
            const repoName = (job.repoUrl || '').replace('https://github.com/', '').replace('.git', '');
            notifyTelegram(
                `❌ **Build process crashed!**\n\n📌 **Dự án:** ${repoName}\n🌿 **Nhánh:** ${job.branch || 'default'}\n⚠️ Process died without exit`
            );
            activeBuilds.delete(buildId);
            emitLogEnd(job.queueId);
            processQueue();
        }
    }
}, 30000);

async function startBuild(job) {
    const { repoUrl, branch, token, lane, flavor } = job;
    let { platform } = job;

    const logId = job.queueId;

    const sendLog = (message, type = 'info') => {
        emitLog(logId, message, type);
    };
    job.sendLog = sendLog;

    sendLog(`Bắt đầu tiến trình build...`, 'info');
    sendLog(`Repository: ${repoUrl}`, 'info');
    sendLog(`Slots: ${activeBuilds.size + 1}/${MAX_CONCURRENT}`, 'info');

    const repoNameShort = repoUrl.replace('https://github.com/', '').replace('.git', '');

    // If platform not specified, auto-detect
    if (!platform) {
        sendLog(`Đang phát hiện loại project...`, 'info');
        const detected = await detectProjectType(repoUrl, branch);
        if (!detected.projectType) {
            sendLog(`Không thể phát hiện loại project, mặc định Android`, 'warn');
            platform = 'android';
        } else {
            platform = detected.projectType === 'flutter' ? 'android' : detected.projectType;
        }
    }

    notifyTelegram(
        `🚀 *Build bắt đầu!*\n\n📌 *Dự án:* ${repoNameShort}\n🌿 *Nhánh:* ${branch || 'default'}\n${platform === 'android' ? '🤖' : '🍏'} *Platform:* ${(platform || 'auto').toUpperCase()}${lane ? ` (${lane})` : ''}${flavor ? `\n🎨 *Flavor:* ${flavor}` : ''}`
    );

    // Validate platform compatibility
    if (platform === 'ios' && process.platform !== 'darwin') {
        sendLog(`❌ iOS build chỉ hoạt động trên macOS (Xcode required)`, 'error');
        sendLog(`📋 Nhưng server này là ${process.platform}`, 'error');
        emitLogEnd(logId);
        processQueue();
        return;
    }

    const platformEmoji = platform === 'android' ? '🤖' : '🍏';
    sendLog(`${platformEmoji} Build: ${platform.toUpperCase()}`, 'success');
    job.platform = platform;

    // Inject token into clone URL
    let finalRepoUrl = repoUrl;
    if (token) {
        try {
            const urlObj = new URL(repoUrl);
            urlObj.username = 'oauth2';
            urlObj.password = token;
            finalRepoUrl = urlObj.toString();
        } catch (e) {
            sendLog('Could not inject token into URL, using original.', 'error');
        }
    }

    const buildId = `${platform}_${Date.now()}_${Math.random().toString(36).slice(2, 5)}`;
    job.buildId = buildId;
    job.startTime = Date.now();
    sendLog(`Build ID: ${buildId}`, 'info');

    const isWindows = process.platform === 'win32';
    const ext = isWindows ? '.ps1' : '.sh';
    const scriptName = `build_${platform}${ext}`;
    const builderDir = path.join(__dirname, '../builder');
    const scriptPath = path.join(builderDir, scriptName);

    // Force tools to output colors and skip buffering
    const env = { 
        ...process.env, 
        FORCE_COLOR: "1",
        TERM: "xterm-256color",
        PYTHONUNBUFFERED: "1",
        FLUTTER_COLOR: "always",
        GRADLE_OPTS: "-Dorg.gradle.console=plain -Dorg.gradle.daemon=false"
    };

    let buildProcess;
    const scriptArgs = [finalRepoUrl, branch || "", buildId, lane || "", flavor || ""];
    
    if (isWindows) {
        const psArgs = scriptArgs.map(a => `"${a.replace(/"/g, '`"')}"`).join(' ');
        buildProcess = spawn('powershell.exe', [
            '-ExecutionPolicy', 'Bypass', '-Command',
            `& '${scriptPath}' ${psArgs}`
        ], { cwd: builderDir, env });
    } else {
        // Use stdbuf on Unix to prevent buffering if available
        let cmd = 'bash';
        let cmdArgs = [scriptPath, ...scriptArgs];
        
        try {
            require('child_process').execSync('which stdbuf', { stdio: 'ignore' });
            cmd = 'stdbuf';
            cmdArgs = ['-oL', '-eL', 'bash', scriptPath, ...scriptArgs];
        } catch(e) {}

        buildProcess = spawn(cmd, cmdArgs, { cwd: builderDir, env, detached: true });
    }

    activeBuilds.set(buildId, { job, process: buildProcess });

    let lastOutputTime = Date.now();

    const handleOutput = (data) => {
        lastOutputTime = Date.now();
        const text = data.toString();
        const lines = text.split(/\r?\n/);
        if (lines.length > 0 && lines[lines.length - 1] === '') {
            lines.pop();
        }
        lines.forEach(line => sendLog(line, 'log'));
    };

    buildProcess.stdout.on('data', handleOutput);
    buildProcess.stderr.on('data', handleOutput);

    let buildFinished = false;

    const killBuildProcess = (reason) => {
        try {
            if (process.platform === 'win32') {
                try { require('child_process').execSync(`taskkill /pid ${buildProcess.pid} /T /F`, { stdio: 'ignore' }); } catch(e) {}
            } else {
                try { process.kill(-buildProcess.pid, 'SIGKILL'); } catch(e) {}
            }
        } catch(e) {}
    };

    const totalTimeout = BUILD_TIMEOUT_MS > 0 ? setTimeout(() => {
        if (buildFinished) return;
        const mins = Math.round(BUILD_TIMEOUT_MS / 60000);
        sendLog(`⏰ Build đã vượt quá thời gian tối đa (${mins} phút). Đang hủy...`, 'error');
        notifyTelegram(
            `⏰ **Build Timeout (${mins}p)!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n⏱️ **ID:** ${buildId}`
        );
        killBuildProcess('total timeout');
    }, BUILD_TIMEOUT_MS) : null;

    const idleCheck = setInterval(() => {
        if (buildFinished) { clearInterval(idleCheck); return; }
        const idleMs = Date.now() - lastOutputTime;
        const elapsedTotal = Math.floor((Date.now() - job.startTime) / 1000);
        const elapsedStr = `${Math.floor(elapsedTotal / 60)}m${String(elapsedTotal % 60).padStart(2, '0')}s`;

        if (IDLE_TIMEOUT_MS > 0 && idleMs >= IDLE_TIMEOUT_MS) {
            const mins = Math.round(IDLE_TIMEOUT_MS / 60000);
            sendLog(`⏰ Build không có output trong ${mins} phút — có thể đã bị treo. Đang hủy...`, 'error');
            notifyTelegram(
                `⏰ **Build bị treo (không output ${mins}p)!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n⏱️ **ID:** ${buildId}`
            );
            killBuildProcess('idle timeout');
            clearInterval(idleCheck);
        } else if (idleMs >= 30000) {
            const idleSec = Math.floor(idleMs / 1000);
            let procStatus = '';
            try {
                if (process.platform === 'win32') {
                    const out = require('child_process').execSync(
                        `powershell -Command "(Get-Process -Id ${buildProcess.pid} -ErrorAction SilentlyContinue).CPU"`,
                        { timeout: 3000, encoding: 'utf8' }
                    ).trim();
                    if (out) procStatus = ` | CPU: ${parseFloat(out).toFixed(1)}s`;
                } else {
                    process.kill(buildProcess.pid, 0);
                    procStatus = ' | process alive';
                }
            } catch { procStatus = ' | process ended?'; }
            sendLog(`⏳ Đang xử lý... (${elapsedStr}, im lặng ${idleSec}s${procStatus})`, 'info');
        }
    }, 30000);

    const finishJob = () => {
        buildFinished = true;
        if (totalTimeout) clearTimeout(totalTimeout);
        clearInterval(idleCheck);
        if (job.keepaliveInterval) clearInterval(job.keepaliveInterval);
        activeBuilds.delete(buildId);
        const elapsed = Math.floor((Date.now() - job.startTime) / 1000);
        console.log(`[BUILD] Finished: ${buildId} (${Math.floor(elapsed / 60)}m${elapsed % 60}s)`);
        emitLogEnd(logId);
        processQueue();
    };

    buildProcess.on('close', (code) => {
        console.log(`[BUILD] Process closed: ${buildId}, code=${code}`);
        if (job._cancelled) { console.log(`[BUILD] Already cancelled, skipping close handler.`); return; }
        try {
            const icon = platform === 'android' ? '🤖' : '🍏';
            const platformName = platform === 'android' ? 'Android' : 'iOS';

            if (code === 0) {
                let fileName = null;
                const buildDir = path.join(builderDir, 'completed_builds', buildId);

                if (fs.existsSync(buildDir)) {
                    if (platform === 'android') {
                        const files = fs.readdirSync(buildDir);
                        const aabFile = files.find(f => f.endsWith('.aab'));
                        const apkFile = files.find(f => f.endsWith('.apk'));
                        fileName = aabFile || apkFile;
                    } else if (platform === 'ios') {
                        if (fs.existsSync(path.join(buildDir, 'Runner.ipa'))) {
                            fileName = 'Runner.ipa';
                        } else if (fs.existsSync(path.join(buildDir, 'Runner.xcarchive.zip'))) {
                            fileName = 'Runner.xcarchive.zip';
                        }
                    }
                } else {
                    sendLog(`Build directory not found: ${buildDir}`, 'error');
                    console.error(`[BUG] Build exited 0 but output dir missing: ${buildDir}`);
                }

                if (!fileName) {
                    sendLog('Build succeeded but no downloadable artifact was found.', 'error');
                    notifyTelegram(
                        `⚠️ **Build xong (exit 0) nhưng không tìm thấy artifact!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n${icon} **Nền tảng:** ${platformName}\n⏱️ **ID:** ${buildId}`
                    );
                    finishJob();
                    return;
                }

                const downloadUrl = `/builds/${buildId}/${fileName}`;
                sendLog('Build completed successfully! 🎉', 'success');
                emitLog(logId, downloadUrl, 'build_success');

                const fullUrl = `${BASE_URL}${downloadUrl}`;
                const elapsed = Math.floor((Date.now() - job.startTime) / 1000);
                const timeStr = `${Math.floor(elapsed / 60)}m${String(elapsed % 60).padStart(2, '0')}s`;
                const repoName = repoUrl.replace('https://github.com/', '').replace('.git', '');

                // Try to get app version
                let versionInfo = '';
                try {
                    const tempDir = process.platform === 'win32'
                        ? path.join(process.env.TEMP || '', `flutter_build_${buildId}`, 'source_code')
                        : path.join('/tmp', `flutter_build_${buildId}`, 'source_code');
                    const pubspec = path.join(tempDir, 'pubspec.yaml');
                    const gradleFile = path.join(tempDir, 'app', 'build.gradle');
                    const gradleKts = path.join(tempDir, 'app', 'build.gradle.kts');
                    if (fs.existsSync(pubspec)) {
                        const content = fs.readFileSync(pubspec, 'utf8');
                        const m = content.match(/version:\s*(\S+)/);
                        if (m) versionInfo = m[1].split('+')[0];
                    } else if (fs.existsSync(gradleFile)) {
                        const content = fs.readFileSync(gradleFile, 'utf8');
                        const vn = content.match(/versionName\s+["']([^"']+)["']/);
                        if (vn) versionInfo = vn[1];
                    } else if (fs.existsSync(gradleKts)) {
                        const content = fs.readFileSync(gradleKts, 'utf8');
                        const vn = content.match(/versionName\s*=\s*"([^"]+)"/);
                        if (vn) versionInfo = vn[1];
                    }
                } catch(e) { console.log('Version detection failed:', e.message); }
                const versionLine = versionInfo ? `\n📦 **Version:** ${versionInfo}` : '';
                const buildType = fileName.endsWith('.aab') ? 'AAB' : fileName.endsWith('.apk') ? 'APK' : fileName.endsWith('.ipa') ? 'IPA' : '';
                const buildTypeLine = buildType ? `\n📋 **Loại:** ${buildType}` : '';

                notifyTelegram(
                    `✅ **Build Thành Công!**\n\n📌 **Dự án:** ${repoName}\n🌿 **Nhánh:** ${branch || 'default'}\n${icon} **Nền tảng:** ${platformName}${buildTypeLine}${versionLine}\n⏱️ **Thời gian:** ${timeStr}`,
                    [[{ text: `📥 Tải ${buildType || 'file'}`, url: fullUrl }]]
                );
            } else {
                const elapsed = Math.floor((Date.now() - job.startTime) / 1000);
                const timeStr = `${Math.floor(elapsed / 60)}m${String(elapsed % 60).padStart(2, '0')}s`;
                const repoName = repoUrl.replace('https://github.com/', '').replace('.git', '');
                const exitMsg = code !== null ? `exit code ${code}` : 'process crashed';
                sendLog(`Build failed (${exitMsg}) ❌`, 'error');
                notifyTelegram(
                    `❌ **Build Thất Bại!**\n\n📌 **Dự án:** ${repoName}\n🌿 **Nhánh:** ${branch || 'default'}\n${icon} **Nền tảng:** ${platformName}\n⚠️ **Lỗi:** ${exitMsg}\n⏱️ **Thời gian:** ${timeStr}`
                );
            }
        } catch (err) {
            console.error(`[CRITICAL] Error in close handler for build ${buildId}:`, err);
            sendLog(`Internal error after build finished: ${err.message}`, 'error');
            notifyTelegram(
                `🔥 **Lỗi hệ thống sau build!**\n\n📌 ${repoUrl}\n⚠️ ${err.message}\n⏱️ ID: ${buildId}`
            );
        }
        finishJob();
    });

    buildProcess.on('error', (err) => {
        sendLog(`Failed to start subprocess: ${err.message}`, 'error');
        notifyTelegram(
            `❌ **Build Lỗi!**\n\n📌 ${repoUrl}\n⚠️ ${err.message}\n⏱️ ID: ${buildId}`
        );
        finishJob();
    });
}

// --- Log streaming ---
app.get('/api/logs/:id', (req, res) => {
    const id = req.params.id;
    const entry = getBuildLog(id);

    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.setHeader('Transfer-Encoding', 'chunked');
    res.flushHeaders();

    for (const log of entry.logs) {
        try { res.write(`data: ${JSON.stringify(log)}\n\n`); } catch(e) {}
    }

    if (entry.finished) {
        try { res.write(`data: ${JSON.stringify({ type: 'end' })}\n\n`); } catch(e) {}
        res.end();
        return;
    }

    entry.listeners.add(res);

    const heartbeat = setInterval(() => {
        try { res.write(`:keepalive\n\n`); } catch(e) { clearInterval(heartbeat); }
    }, 15000);

    req.on('close', () => {
        clearInterval(heartbeat);
        entry.listeners.delete(res);
    });
});

app.get('/api/logs-snapshot/:id', (req, res) => {
    const id = req.params.id;
    const entry = getBuildLog(id);
    res.json({ logs: entry.logs, finished: entry.finished });
});

// --- Task management ---

app.get('/api/tasks', (req, res) => {
    const tasks = [];

    for (const [buildId, { job }] of activeBuilds) {
        const elapsed = Math.floor((Date.now() - job.startTime) / 1000);
        tasks.push({
            id: job.queueId,
            buildId,
            platform: job.platform,
            repoUrl: job.repoUrl,
            branch: job.branch || 'default',
            status: 'running',
            elapsed: `${Math.floor(elapsed / 60)}m ${elapsed % 60}s`,
        });
    }

    buildQueue.forEach((job, index) => {
        tasks.push({
            id: job.queueId,
            platform: job.platform,
            repoUrl: job.repoUrl,
            branch: job.branch || 'default',
            status: job.paused ? 'paused' : 'queued',
            position: index + 1,
        });
    });

    res.json({ tasks, maxConcurrent: MAX_CONCURRENT, active: activeBuilds.size + startingBuilds.size });
});

app.post('/api/cancel', (req, res) => {
    const { id } = req.body;
    if (!id) return res.status(400).json({ error: 'Missing task id' });

    // Cancel running build
    const active = activeBuilds.get(id);
    if (active) {
        console.log(`🔪 Cancelling build: ${id}`);
        active.job._cancelled = true;
        try {
            if (process.platform === 'win32') {
                try { require('child_process').execSync(`taskkill /pid ${active.process.pid} /T /F`, { stdio: 'ignore' }); } catch(e) {}
                try { require('child_process').execSync(`taskkill /IM java.exe /F /T`, { stdio: 'ignore' }); } catch(e) {}
            } else {
                try { process.kill(-active.process.pid, 'SIGKILL'); } catch(e) {}
                try { require('child_process').execSync(`killall -9 java`, { stdio: 'ignore' }); } catch(e) {}
            }
        } catch { }
        active.job.sendLog('⛔ Build đã bị hủy bởi người dùng.', 'error');
        notifyTelegram(`⛔ **Build Đã Hủy**\n\n📌 ${active.job.repoUrl}\n⏱️ ID: ${id}`);
        activeBuilds.delete(id);
        emitLogEnd(active.job.queueId);
        processQueue();
        return res.json({ success: true, message: 'Build cancelled' });
    }

    // Cancel queued job
    const index = buildQueue.findIndex(j => j.queueId === id);
    if (index !== -1) {
        const removed = buildQueue.splice(index, 1)[0];
        removed.sendLog('⛔ Build đã bị hủy khỏi hàng đợi.', 'error');
        emitLogEnd(removed.queueId);
        return res.json({ success: true, message: 'Queued job removed' });
    }

    res.status(404).json({ error: 'Task not found' });
});

app.post('/api/queue/pause', (req, res) => {
    const { id } = req.body;
    if (!id) return res.status(400).json({ error: 'Missing id' });
    const job = buildQueue.find(j => j.queueId === id);
    if (!job) return res.status(404).json({ error: 'Not found in queue' });
    job.paused = !job.paused;
    job.sendLog(job.paused ? '⏸️ Build đã tạm dừng trong hàng đợi.' : '▶️ Build đã tiếp tục trong hàng đợi.', 'info');
    if (!job.paused) processQueue();
    res.json({ success: true, paused: job.paused });
});

app.post('/api/queue/move', (req, res) => {
    const { id, direction } = req.body;
    if (!id || !direction) return res.status(400).json({ error: 'Missing id or direction' });
    const index = buildQueue.findIndex(j => j.queueId === id);
    if (index === -1) return res.status(404).json({ error: 'Not found in queue' });
    const newIndex = direction === 'up' ? index - 1 : index + 1;
    if (newIndex < 0 || newIndex >= buildQueue.length) return res.status(400).json({ error: 'Cannot move further' });
    [buildQueue[index], buildQueue[newIndex]] = [buildQueue[newIndex], buildQueue[index]];
    res.json({ success: true, from: index, to: newIndex });
});

app.post('/api/queue/remove', (req, res) => {
    const { id } = req.body;
    if (!id) return res.status(400).json({ error: 'Missing id' });
    const index = buildQueue.findIndex(j => j.queueId === id);
    if (index === -1) return res.status(404).json({ error: 'Not found in queue' });
    const removed = buildQueue.splice(index, 1)[0];
    removed.sendLog('🗑️ Build đã bị xóa khỏi hàng đợi.', 'error');
    emitLogEnd(removed.queueId);
    res.json({ success: true });
});

app.post('/api/build', (req, res) => {
    const { repoUrl, branch, token, lane, platform, flavor } = req.body;
    console.log(`[BUILD REQUEST] repo=${repoUrl} branch=${branch} platform=${platform} active=${activeBuilds.size} queue=${buildQueue.length}`);

    if (!repoUrl) return res.status(400).json({ error: 'Missing repoUrl' });
    if (platform && platform !== 'android' && platform !== 'ios') {
        return res.status(400).json({ error: 'Invalid platform' });
    }

    const queueId = `q_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    getBuildLog(queueId);
    const sendLog = (message, type = 'info') => {
        emitLog(queueId, message, type);
    };

    const repoName = repoUrl.replace('https://github.com/', '').replace('.git', '');
    sendLog(`📌 ${repoName} · ${branch || 'default'} · ${(platform || 'auto').toUpperCase()}`, 'info');

    const job = { queueId, platform: platform || null, repoUrl, branch, token, lane, flavor, res: null, sendLog };

    buildQueue.push(job);
    const totalActive = activeBuilds.size + startingBuilds.size;
    const queued = totalActive >= MAX_CONCURRENT;
    if (queued) {
        const pos = buildQueue.length;
        sendLog(`⏳ Đã đưa vào hàng đợi — Vị trí #${pos}/${buildQueue.length}. Đang chạy ${totalActive}/${MAX_CONCURRENT} builds.`, 'info');
        job._lastQueuePos = pos;
        job._lastPaused = false;
    } else {
        sendLog(`🚀 Build sẽ bắt đầu ngay...`, 'info');
    }
    processQueue();

    res.json({ success: true, queueId, queued, position: queued ? buildQueue.length : 0 });
});

app.listen(PORT, '0.0.0.0', async () => {
    const publicIP = await getPublicIP();
    const lanIP = getLanIP();

    if (publicIP && publicIP !== lanIP && !process.env.BASE_URL) {
        BASE_URL = `http://${publicIP}:${PORT}`;
        console.log(`🌍 Public IP (VPS): ${publicIP}`);
        console.log(`🏠 LAN IP: ${lanIP}`);
    } else if (!process.env.BASE_URL) {
        BASE_URL = `http://${lanIP}:${PORT}`;
        console.log(`🏠 LAN IP: ${lanIP}`);
    }

    console.log(`🖥️  Server (Node):   http://${lanIP}:${PORT}`);
    if (publicIP && publicIP !== lanIP) {
        console.log(`🌍 Server (Public): http://${publicIP}:${PORT}`);
    }
    console.log(`📲 Telegram link:   ${BASE_URL}`);
});

// --- Cleanup: kill build process when server stops ---
function shutdown() {
    console.log('\n🛑 Server shutting down...');
    const { execSync } = require('child_process');

    for (const [buildId, { process: proc }] of activeBuilds) {
        console.log(`🔪 Killing build process: ${buildId} (pid ${proc.pid})`);
        try {
            if (process.platform === 'win32') {
                try { execSync(`taskkill /pid ${proc.pid} /T /F`, { stdio: 'ignore' }); } catch(e) {}
            } else {
                try { process.kill(-proc.pid, 'SIGKILL'); } catch(e) {}
            }
        } catch { }
    }

    console.log('🔪 Killing all Java/Gradle processes...');
    if (process.platform === 'win32') {
        try { execSync('taskkill /IM java.exe /F /T', { stdio: 'ignore' }); } catch(e) {}
        try { execSync('taskkill /IM javaw.exe /F /T', { stdio: 'ignore' }); } catch(e) {}
    } else {
        try { execSync('killall -9 java', { stdio: 'ignore' }); } catch(e) {}
    }

    activeBuilds.clear();
    buildQueue.length = 0;
    console.log('✅ All builds and Java processes killed. Bye!');
    process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
