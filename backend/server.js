const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const cors = require('cors');

const app = express();
const PORT = 3000;

const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || '8793252151:AAH-P7LoLGKKo5_pPBgk9MPlmVpOKsXPSN0';
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID || '2019979030';

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
        } catch {}
    }
    return null;
}

// Will be set after server starts
let BASE_URL = process.env.BASE_URL || `http://${getLanIP()}`;

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '../frontend')));
app.use('/builds', express.static(path.join(__dirname, '../builder/completed_builds')));

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

function notifyTelegram(message) {
    fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage?chat_id=${TELEGRAM_CHAT_ID}&parse_mode=Markdown&text=${encodeURIComponent(message)}`)
        .catch(console.error);
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
    const { repoUrl, branch } = req.body;
    if (!repoUrl) return res.status(400).json({ error: 'Missing repoUrl' });

    try {
        const { projectType, flavors } = await detectProjectType(repoUrl, branch);
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

        // Match productFlavors block and extract flavor names
        const match = content.match(/productFlavors\s*\{([\s\S]*?)\n\s{4}\}/);
        if (!match) continue;

        const block = match[1];
        // Groovy: flavorName { ... }  or  Kts: create("flavorName") { ... }
        const flavors = [];
        const groovyMatches = block.matchAll(/^\s{8}(\w+)\s*\{/gm);
        for (const m of groovyMatches) {
            flavors.push(m[1]);
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
        } catch {}
    }
}

// --- Build System (parallel) ---

const MAX_CONCURRENT = parseInt(process.env.MAX_BUILDS) || 3;
const buildQueue = [];
const activeBuilds = new Map(); // buildId → { job, process }

function processQueue() {
    while (activeBuilds.size < MAX_CONCURRENT && buildQueue.length > 0) {
        const job = buildQueue.shift();
        startBuild(job);
    }
    // Notify remaining queue positions
    buildQueue.forEach((qJob, index) => {
        qJob.sendLog(`Hàng đợi: vị trí ${index + 1}/${buildQueue.length}. Đang chạy ${activeBuilds.size}/${MAX_CONCURRENT} builds.`, 'info');
    });
}

async function startBuild(job) {
    const { repoUrl, branch, token, lane, flavor, res, sendLog } = job;
    let { platform } = job;

    sendLog(`Bắt đầu tiến trình build...`, 'info');
    sendLog(`Repository: ${repoUrl}`, 'info');
    sendLog(`Slots: ${activeBuilds.size + 1}/${MAX_CONCURRENT}`, 'info');

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

    // Validate platform compatibility
    if (platform === 'ios' && process.platform !== 'darwin') {
        sendLog(`❌ iOS build chỉ hoạt động trên macOS (Xcode required)`, 'error');
        sendLog(`📋 Nhưng server này là ${process.platform}`, 'error');
        job.res.end();
        activeBuilds.delete(job.buildId);
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

    let buildProcess;
    const args = [finalRepoUrl, branch || "", buildId, lane || "", flavor || ""];
    if (isWindows) {
        buildProcess = spawn('powershell.exe', [
            '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args
        ], { cwd: builderDir });
    } else {
        buildProcess = spawn('bash', [scriptPath, ...args], { cwd: builderDir, detached: true });
    }

    activeBuilds.set(buildId, { job, process: buildProcess });

    buildProcess.stdout.on('data', (data) => sendLog(data.toString(), 'log'));
    buildProcess.stderr.on('data', (data) => sendLog(data.toString(), 'error'));

    const finishJob = () => {
        activeBuilds.delete(buildId);
        res.end();
        processQueue();
    };

    buildProcess.on('close', (code) => {
        const icon = platform === 'android' ? '🤖' : '🍏';
        const platformName = platform === 'android' ? 'Android' : 'iOS';

        if (code === 0) {
            let fileName = null;
            const buildDir = path.join(builderDir, 'completed_builds', buildId);

            if (platform === 'android') {
                // Check for AAB first (bundle lane), then APK
                const aabFile = fs.readdirSync(buildDir).find(f => f.endsWith('.aab'));
                const apkFile = fs.readdirSync(buildDir).find(f => f.endsWith('.apk'));
                fileName = aabFile || apkFile;
            } else if (platform === 'ios') {
                if (fs.existsSync(path.join(buildDir, 'Runner.ipa'))) {
                    fileName = 'Runner.ipa';
                } else if (fs.existsSync(path.join(buildDir, 'Runner.xcarchive.zip'))) {
                    fileName = 'Runner.xcarchive.zip';
                }
            }

            if (!fileName) {
                sendLog('Build succeeded but no downloadable artifact was found.', 'error');
                finishJob();
                return;
            }

            const downloadUrl = `/builds/${buildId}/${fileName}`;
            sendLog('Build completed successfully! 🎉', 'success');
            res.write(`data: ${JSON.stringify({ message: downloadUrl, type: 'build_success', buildId, platform })}\n\n`);

            const lanUrl = `http://${getLanIP()}:${PORT}${downloadUrl}`;
            const publicIP = BASE_URL.match(/\d+\.\d+\.\d+\.\d+/)?.[0];
            const publicUrl = publicIP ? `http://${publicIP}:${PORT}${downloadUrl}` : null;
            const downloadLinks = publicUrl && publicUrl !== lanUrl
                ? `🏠 [LAN](${lanUrl})\n🌍 [Public](${publicUrl})`
                : `📦 [Download](${lanUrl})`;
            notifyTelegram(
                `✅ **Build Thành Công!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n${icon} **Nền tảng:** ${platformName}\n${downloadLinks}\n⏱️ **ID:** ${buildId}`
            );
        } else if (code !== null) {
            sendLog(`Build failed with exit code ${code} ❌`, 'error');
            notifyTelegram(
                `❌ **Build Thất Bại!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n${icon} **Nền tảng:** ${platformName}\n⏱️ **ID:** ${buildId}`
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

// --- Task management ---

app.get('/api/tasks', (req, res) => {
    const tasks = [];

    // Running builds
    for (const [buildId, { job }] of activeBuilds) {
        const elapsed = Math.floor((Date.now() - job.startTime) / 1000);
        tasks.push({
            id: buildId,
            platform: job.platform,
            repoUrl: job.repoUrl,
            branch: job.branch || 'default',
            status: 'running',
            elapsed: `${Math.floor(elapsed / 60)}m ${elapsed % 60}s`,
        });
    }

    // Queued jobs
    buildQueue.forEach((job, index) => {
        tasks.push({
            id: job.queueId,
            platform: job.platform,
            repoUrl: job.repoUrl,
            branch: job.branch || 'default',
            status: 'queued',
            position: index + 1,
        });
    });

    res.json({ tasks, maxConcurrent: MAX_CONCURRENT, active: activeBuilds.size });
});

app.post('/api/cancel', (req, res) => {
    const { id } = req.body;
    if (!id) return res.status(400).json({ error: 'Missing task id' });

    // Cancel running build
    const active = activeBuilds.get(id);
    if (active) {
        console.log(`🔪 Cancelling build: ${id}`);
        try {
            if (process.platform === 'win32') {
                require('child_process').execSync(`taskkill /pid ${active.process.pid} /T /F`, { stdio: 'ignore' });
            } else {
                process.kill(-active.process.pid, 'SIGKILL');
            }
        } catch {}
        active.job.sendLog('⛔ Build đã bị hủy bởi người dùng.', 'error');
        notifyTelegram(`⛔ **Build Đã Hủy**\n\n📌 ${active.job.repoUrl}\n⏱️ ID: ${id}`);
        return res.json({ success: true, message: 'Build cancelled' });
    }

    // Cancel queued job
    const index = buildQueue.findIndex(j => j.queueId === id);
    if (index !== -1) {
        const removed = buildQueue.splice(index, 1)[0];
        removed.sendLog('⛔ Build đã bị hủy khỏi hàng đợi.', 'error');
        removed.res.end();
        return res.json({ success: true, message: 'Queued job removed' });
    }

    res.status(404).json({ error: 'Task not found' });
});

app.post('/api/build', (req, res) => {
    const { repoUrl, branch, token, lane, platform, flavor } = req.body;

    if (!repoUrl) return res.status(400).json({ error: 'Missing repoUrl' });
    if (platform && platform !== 'android' && platform !== 'ios') {
        return res.status(400).json({ error: 'Invalid platform' });
    }

    // SSE setup
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();

    const sendLog = (message, type = 'info') => {
        res.write(`data: ${JSON.stringify({ message, type })}\n\n`);
    };

    const queueId = `q_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    const job = { queueId, platform: platform || null, repoUrl, branch, token, lane, flavor, res, sendLog };

    req.on('close', () => {
        const index = buildQueue.indexOf(job);
        if (index !== -1) {
            buildQueue.splice(index, 1);
            console.log('Client disconnected, removed from queue.');
        }
    });

    if (activeBuilds.size >= MAX_CONCURRENT) {
        sendLog(`Đã đưa vào hàng đợi. Vị trí: ${buildQueue.length + 1}. Đang chạy ${activeBuilds.size}/${MAX_CONCURRENT} builds.`, 'info');
    }

    buildQueue.push(job);
    processQueue();
});

app.listen(PORT, '0.0.0.0', async () => {
    const publicIP = await getPublicIP();
    const lanIP = getLanIP();
    const hasNginx = process.env.NGINX === '1';
    const portSuffix = hasNginx ? '' : `:${PORT}`;

    if (publicIP && publicIP !== lanIP && !process.env.BASE_URL) {
        BASE_URL = `http://${publicIP}${portSuffix}`;
        console.log(`🌍 Public IP (VPS): ${publicIP}`);
        console.log(`🏠 LAN IP: ${lanIP}`);
    } else if (!process.env.BASE_URL) {
        BASE_URL = `http://${lanIP}${portSuffix}`;
        console.log(`🏠 LAN IP: ${lanIP}`);
    }

    if (hasNginx) {
        console.log(`🌐 Server (Nginx):  http://${publicIP || lanIP}:80`);
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
    // Kill all running builds
    for (const [buildId, { process: proc }] of activeBuilds) {
        console.log(`🔪 Killing build: ${buildId}`);
        try {
            if (process.platform === 'win32') {
                require('child_process').execSync(`taskkill /pid ${proc.pid} /T /F`, { stdio: 'ignore' });
            } else {
                process.kill(-proc.pid, 'SIGKILL');
            }
        } catch {}
    }
    activeBuilds.clear();
    buildQueue.length = 0;
    console.log(`✅ All ${activeBuilds.size} builds cancelled. Bye!`);
    process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
