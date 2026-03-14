const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const cors = require('cors');

const app = express();
const PORT = 3000;
const HISTORY_PATH = path.join(__dirname, 'build_history.json');

app.use(cors());
app.use(express.json());
// Serve frontend static files
app.use(express.static(path.join(__dirname, '../frontend')));
app.use('/builds', express.static(path.join(__dirname, '../builder/completed_builds')));

const buildQueue = [];
const builds = new Map();
let currentBuild = null;

const loadHistory = () => {
    if (fs.existsSync(HISTORY_PATH)) {
        try {
            const data = JSON.parse(fs.readFileSync(HISTORY_PATH, 'utf-8'));
            if (Array.isArray(data)) {
                data.forEach((b) => builds.set(b.id, { ...b, logs: [], sseClients: new Set(), process: null, token: null }));
            }
        } catch (e) {
            console.warn('Failed to load build history:', e.message);
        }
    }
};

const saveHistory = () => {
    const snapshot = Array.from(builds.values()).map((b) => ({
        id: b.id,
        platform: b.platform,
        repoUrl: b.repoUrl,
        branch: b.branch,
        lane: b.lane,
        status: b.status,
        createdAt: b.createdAt,
        startedAt: b.startedAt || null,
        finishedAt: b.finishedAt || null,
        downloadUrl: b.downloadUrl || null,
        exitCode: b.exitCode ?? null
    }));
    try {
        fs.writeFileSync(HISTORY_PATH, JSON.stringify(snapshot, null, 2));
    } catch (e) {
        console.warn('Failed to save build history:', e.message);
    }
};

const addLog = (build, message, type = 'info') => {
    const entry = { ts: Date.now(), type, message };
    build.logs.push(entry);
    if (build.logs.length > 1000) {
        build.logs.shift();
    }
    build.sseClients.forEach((client) => {
        try {
            client.write(`data: ${JSON.stringify({ message, type, buildId: build.id, status: build.status })}\n\n`);
        } catch (e) {
            // Ignore broken pipe
        }
    });
};

const setStatus = (build, status) => {
    build.status = status;
    addLog(build, `Status: ${status}`, status === 'running' ? 'info' : 'system');
    saveHistory();
};

const startNextBuild = () => {
    if (currentBuild || buildQueue.length === 0) return;
    const next = buildQueue.shift();
    currentBuild = next;
    next.startedAt = Date.now();
    setStatus(next, 'running');

    const builderDir = path.join(__dirname, '../builder');
    const scriptName = next.platform === 'android' ? 'build_android.sh' : 'build_ios.sh';
    const scriptPath = path.join(builderDir, scriptName);

    let finalRepoUrl = next.repoUrl;
    if (next.token) {
        try {
            const urlObj = new URL(next.repoUrl);
            urlObj.username = 'oauth2';
            urlObj.password = next.token;
            finalRepoUrl = urlObj.toString();
        } catch (e) {
            addLog(next, 'Could not parse URL to inject token, using original URL.', 'error');
        }
    }

    const args = [scriptPath, finalRepoUrl, next.branch || "", next.id, next.lane || ""];
    const buildProcess = spawn('bash', args, { cwd: builderDir, detached: true });
    next.process = buildProcess;

    buildProcess.stdout.on('data', (data) => addLog(next, data.toString(), 'log'));
    buildProcess.stderr.on('data', (data) => addLog(next, data.toString(), 'error'));

    buildProcess.on('close', (code) => {
        next.exitCode = code;
        next.finishedAt = Date.now();
        if (code === 0) {
            let fileName = 'app-release.apk';
            if (next.platform === 'ios') {
                const iosDir = path.join(builderDir, 'completed_builds', next.id);
                const ipaPath = path.join(iosDir, 'Runner.ipa');
                const xcarchiveZipPath = path.join(iosDir, 'Runner.xcarchive.zip');

                if (fs.existsSync(ipaPath)) {
                    fileName = 'Runner.ipa';
                } else if (fs.existsSync(xcarchiveZipPath)) {
                    fileName = 'Runner.xcarchive.zip';
                } else {
                    addLog(next, 'Build succeeded but no downloadable artifact was found.', 'error');
                    setStatus(next, 'failed');
                    currentBuild = null;
                    startNextBuild();
                    return;
                }
            }
            const downloadUrl = `/builds/${next.id}/${fileName}`;
            next.downloadUrl = downloadUrl;
            addLog(next, `Build completed successfully! 🎉`, 'success');
            next.sseClients.forEach((client) => {
                client.write(`data: ${JSON.stringify({ message: downloadUrl, type: 'build_success', buildId: next.id, platform: next.platform })}\n\n`);
            });
            setStatus(next, 'success');
        } else {
            if (next.status !== 'canceled') {
                addLog(next, `Build failed with exit code ${code} ❌`, 'error');
                setStatus(next, 'failed');
            }
        }
        next.sseClients.forEach((client) => {
            try { client.end(); } catch (e) {}
        });
        next.sseClients.clear();
        currentBuild = null;
        startNextBuild();
    });

    buildProcess.on('error', (err) => {
        addLog(next, `Failed to start subprocess: ${err.message}`, 'error');
        next.finishedAt = Date.now();
        setStatus(next, 'failed');
        next.sseClients.forEach((client) => {
            try { client.end(); } catch (e) {}
        });
        next.sseClients.clear();
        currentBuild = null;
        startNextBuild();
    });
};

loadHistory();

app.post('/api/repos', async (req, res) => {
    const { token } = req.body;
    if (!token) {
        return res.status(400).json({ error: 'Missing access token' });
    }

    try {
        let allRepos = [];
        let page = 1;
        let hasMore = true;

        while (hasMore) { // Fetch all pages
            const response = await fetch(`https://api.github.com/user/repos?per_page=100&page=${page}&sort=updated&affiliation=owner,collaborator,organization_member`, {
                headers: {
                    'Authorization': `token ${token}`,
                    'Accept': 'application/vnd.github.v3+json',
                    'User-Agent': 'Flutter-Remote-Builder'
                }
            });

            if (!response.ok) {
                throw new Error(`GitHub API error: ${response.statusText}`);
            }

            const data = await response.json();
            if (data.length === 0) {
                hasMore = false;
            } else {
                const mapped = data.map(repo => ({
                    name: repo.full_name,
                    url: repo.clone_url,
                    private: repo.private
                }));
                allRepos = allRepos.concat(mapped);

                // If it returns less than 100, we hit the last page
                if (data.length < 100) {
                    hasMore = false;
                } else {
                    page++;
                }
            }
        }

        res.json({ repos: allRepos });
    } catch (error) {
        console.error('Fetch repos error:', error.message);
        res.status(500).json({ error: error.message });
    }
});

app.post('/api/branches', async (req, res) => {
    const { token, repoFullName } = req.body;
    if (!token || !repoFullName) {
        return res.status(400).json({ error: 'Missing access token or repository name' });
    }

    try {
        const response = await fetch(`https://api.github.com/repos/${repoFullName}/branches?per_page=100`, {
            headers: {
                'Authorization': `token ${token}`,
                'Accept': 'application/vnd.github.v3+json',
                'User-Agent': 'Flutter-Remote-Builder'
            }
        });

        if (!response.ok) {
            throw new Error(`GitHub API error: ${response.statusText}`);
        }

        const data = await response.json();
        const branches = data.map(branch => branch.name);

        res.json({ branches });
    } catch (error) {
        console.error('Fetch branches error:', error.message);
        res.status(500).json({ error: error.message });
    }
});

app.post('/api/build', (req, res) => {
    const { platform, repoUrl, branch, token, lane } = req.body;

    if (!platform || !repoUrl) {
        return res.status(400).json({ error: 'Missing platform or repoUrl' });
    }

    if (platform !== 'android' && platform !== 'ios') {
        return res.status(400).json({ error: 'Platform must be android or ios' });
    }

    // Set up Server-Sent Events for streaming logs
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();

    const buildId = `${platform}_${Date.now()}`;
    const build = {
        id: buildId,
        platform,
        repoUrl,
        branch: branch || "",
        lane: lane || "",
        token: token || null,
        status: 'pending',
        createdAt: Date.now(),
        logs: [],
        sseClients: new Set(),
        process: null
    };
    builds.set(buildId, build);
    saveHistory();

    build.sseClients.add(res);
    addLog(build, `Queued build for ${platform}`, 'info');
    addLog(build, `Repository: ${repoUrl}`, 'info');
    addLog(build, `Build ID: ${buildId}`, 'info');

    const queuePosition = buildQueue.length + (currentBuild ? 1 : 0);
    res.write(`data: ${JSON.stringify({ message: `Queued at position ${queuePosition}`, type: 'status', buildId, status: 'pending', queuePosition })}\n\n`);

    buildQueue.push(build);
    startNextBuild();

    const keepAlive = setInterval(() => {
        try { res.write(`data: ${JSON.stringify({ type: 'ping', buildId })}\n\n`); } catch (e) {}
    }, 15000);

    req.on('close', () => {
        clearInterval(keepAlive);
        build.sseClients.delete(res);
    });
});

app.get('/api/builds', (req, res) => {
    const list = Array.from(builds.values())
        .sort((a, b) => b.createdAt - a.createdAt)
        .map((b) => ({
            id: b.id,
            platform: b.platform,
            repoUrl: b.repoUrl,
            branch: b.branch,
            lane: b.lane,
            status: b.status,
            createdAt: b.createdAt,
            startedAt: b.startedAt || null,
            finishedAt: b.finishedAt || null,
            downloadUrl: b.downloadUrl || null
        }));
    res.json({ builds: list });
});

app.get('/api/queue', (req, res) => {
    res.json({
        current: currentBuild ? {
            id: currentBuild.id,
            platform: currentBuild.platform,
            repoUrl: currentBuild.repoUrl,
            branch: currentBuild.branch,
            lane: currentBuild.lane,
            status: currentBuild.status,
            startedAt: currentBuild.startedAt || null
        } : null,
        pending: buildQueue.map((b) => ({
            id: b.id,
            platform: b.platform,
            repoUrl: b.repoUrl,
            branch: b.branch,
            lane: b.lane,
            status: b.status,
            createdAt: b.createdAt
        }))
    });
});

app.get('/api/builds/:id', (req, res) => {
    const build = builds.get(req.params.id);
    if (!build) return res.status(404).json({ error: 'Build not found' });
    res.json({
        id: build.id,
        platform: build.platform,
        repoUrl: build.repoUrl,
        branch: build.branch,
        lane: build.lane,
        status: build.status,
        createdAt: build.createdAt,
        startedAt: build.startedAt || null,
        finishedAt: build.finishedAt || null,
        downloadUrl: build.downloadUrl || null,
        logs: build.logs.slice(-200)
    });
});

app.post('/api/builds/:id/cancel', (req, res) => {
    const build = builds.get(req.params.id);
    if (!build) return res.status(404).json({ error: 'Build not found' });
    if (build.status === 'success' || build.status === 'failed' || build.status === 'canceled') {
        return res.json({ status: build.status, message: 'Build already finished' });
    }

    if (build.status === 'pending') {
        const idx = buildQueue.findIndex((b) => b.id === build.id);
        if (idx !== -1) buildQueue.splice(idx, 1);
        build.finishedAt = Date.now();
        setStatus(build, 'canceled');
        build.sseClients.forEach((client) => { try { client.end(); } catch (e) {} });
        build.sseClients.clear();
        return res.json({ status: 'canceled' });
    }

    if (build.status === 'running' && build.process) {
        addLog(build, 'Cancel requested. Stopping build...', 'system');
        try {
            // Kill the entire process group to stop any child processes (e.g., docker)
            process.kill(-build.process.pid, 'SIGTERM');
        } catch (e) {
            build.process.kill('SIGTERM');
        }
        const killTimer = setTimeout(() => {
            if (build.process && !build.process.killed) {
                try {
                    process.kill(-build.process.pid, 'SIGKILL');
                } catch (e) {
                    build.process.kill('SIGKILL');
                }
            }
        }, 10000);
        build.process.on('close', () => clearTimeout(killTimer));
        build.finishedAt = Date.now();
        setStatus(build, 'canceled');
        return res.json({ status: 'canceled' });
    }

    res.status(400).json({ error: 'Unable to cancel build' });
});

app.listen(PORT, () => {
    console.log(`Server is running at http://localhost:${PORT}`);
});
