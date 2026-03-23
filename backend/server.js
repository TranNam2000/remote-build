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

// Auto-detect LAN IP for Telegram download links
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
const BASE_URL = process.env.BASE_URL || `http://${getLanIP()}:${PORT}`;

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

// --- Build Queue ---

const buildQueue = [];
let isBuilding = false;

function processQueue() {
    if (isBuilding || buildQueue.length === 0) return;

    isBuilding = true;
    const job = buildQueue.shift();

    buildQueue.forEach((qJob, index) => {
        qJob.sendLog(`Bạn đang ở vị trí số ${index + 1} trong hàng đợi...`, 'info');
    });

    const { platform, repoUrl, branch, token, lane, res, sendLog } = job;

    sendLog(`Bắt đầu tiến trình build cho ${platform}...`, 'info');
    sendLog(`Repository: ${repoUrl}`, 'info');

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

    const buildId = `${platform}_${Date.now()}`;
    sendLog(`Build ID: ${buildId}`, 'info');

    // Choose script
    const isWindows = process.platform === 'win32';
    const ext = isWindows ? '.bat' : '.sh';
    const scriptName = `build_${platform}${ext}`;
    const builderDir = path.join(__dirname, '../builder');
    const scriptPath = path.join(builderDir, scriptName);

    // Spawn build process
    let buildProcess;
    const args = [finalRepoUrl, branch || "", buildId, lane || ""];
    if (isWindows) {
        buildProcess = spawn(scriptPath, args, { cwd: builderDir, shell: true });
    } else {
        buildProcess = spawn('bash', [scriptPath, ...args], { cwd: builderDir });
    }

    buildProcess.stdout.on('data', (data) => sendLog(data.toString(), 'log'));
    buildProcess.stderr.on('data', (data) => sendLog(data.toString(), 'error'));

    const finishJob = () => {
        res.end();
        isBuilding = false;
        processQueue();
    };

    buildProcess.on('close', (code) => {
        const icon = platform === 'android' ? '🤖' : '🍏';
        const platformName = platform === 'android' ? 'Android' : 'iOS';

        if (code === 0) {
            // Detect artifact filename
            let fileName = 'app-release.apk';
            if (platform === 'ios') {
                const buildDir = path.join(builderDir, 'completed_builds', buildId);
                if (fs.existsSync(path.join(buildDir, 'Runner.ipa'))) {
                    fileName = 'Runner.ipa';
                } else if (fs.existsSync(path.join(buildDir, 'Runner.xcarchive.zip'))) {
                    fileName = 'Runner.xcarchive.zip';
                } else {
                    sendLog('Build succeeded but no downloadable artifact was found.', 'error');
                    finishJob();
                    return;
                }
            }

            const downloadUrl = `/builds/${buildId}/${fileName}`;
            sendLog('Build completed successfully! 🎉', 'success');
            res.write(`data: ${JSON.stringify({ message: downloadUrl, type: 'build_success', buildId, platform })}\n\n`);

            const fullDownloadUrl = `${BASE_URL}${downloadUrl}`;
            notifyTelegram(
                `✅ **Build Thành Công!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n${icon} **Nền tảng:** ${platformName}\n📦 **Tải xuống:** [Download](${fullDownloadUrl})\n⏱️ **ID:** ${buildId}`
            );
        } else {
            sendLog(`Build failed with exit code ${code} ❌`, 'error');

            notifyTelegram(
                `❌ **Build Thất Bại!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n${icon} **Nền tảng:** ${platformName}\n⏱️ **ID:** ${buildId}\n\nXem chi tiết trên bảng điều khiển Web.`
            );
        }
        finishJob();
    });

    buildProcess.on('error', (err) => {
        sendLog(`Failed to start subprocess: ${err.message}`, 'error');
        notifyTelegram(
            `❌ **Build Lỗi!**\n\n📌 **Dự án:** ${repoUrl}\n🌿 **Nhánh:** ${branch}\n${icon} **Nền tảng:** ${platformName}\n⚠️ **Lỗi:** ${err.message}\n⏱️ **ID:** ${buildId}`
        );
        finishJob();
    });
}

app.post('/api/build', (req, res) => {
    const { platform, repoUrl, branch, token, lane } = req.body;

    if (!platform || !repoUrl) return res.status(400).json({ error: 'Missing platform or repoUrl' });
    if (platform !== 'android' && platform !== 'ios') return res.status(400).json({ error: 'Platform must be android or ios' });

    // SSE setup
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();

    const sendLog = (message, type = 'info') => {
        res.write(`data: ${JSON.stringify({ message, type })}\n\n`);
    };

    const job = { platform, repoUrl, branch, token, lane, res, sendLog };

    req.on('close', () => {
        const index = buildQueue.indexOf(job);
        if (index !== -1) {
            buildQueue.splice(index, 1);
            console.log('Client disconnected, removed from queue.');
        }
    });

    if (isBuilding) {
        sendLog(`Đã đưa vào hàng đợi. Vị trí: ${buildQueue.length + 1}. Vui lòng chờ...`, 'info');
    }

    buildQueue.push(job);
    processQueue();
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server is running at ${BASE_URL}`);
});
