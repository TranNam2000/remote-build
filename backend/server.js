const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const cors = require('cors');

const app = express();
const PORT = 3000;

app.use(cors());
app.use(express.json());
// Serve frontend static files
app.use(express.static(path.join(__dirname, '../frontend')));
app.use('/builds', express.static(path.join(__dirname, '../builder/completed_builds')));

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

    const sendLog = (message, type = 'info') => {
        res.write(`data: ${JSON.stringify({ message, type })}\n\n`);
    };

    sendLog(`Starting build process for ${platform}...`, 'info');
    sendLog(`Repository: ${repoUrl}`, 'info');

    let finalRepoUrl = repoUrl;
    if (token) {
        try {
            const urlObj = new URL(repoUrl);
            urlObj.username = 'oauth2';
            urlObj.password = token;
            finalRepoUrl = urlObj.toString();
        } catch (e) {
            sendLog('Could not parse URL to inject token, using original URL.', 'error');
        }
    }

    const buildId = `${platform}_${Date.now()}`;
    sendLog(`Build ID: ${buildId}`, 'info');

    // Choose the right script
    const scriptName = platform === 'android' ? 'build_android.sh' : 'build_ios.sh';
    const builderDir = path.join(__dirname, '../builder');
    const scriptPath = path.join(builderDir, scriptName);

    const args = [scriptPath, finalRepoUrl, branch || "", buildId, lane || ""];

    // Spawn the build process
    const buildProcess = spawn('bash', args, { cwd: builderDir });

    buildProcess.stdout.on('data', (data) => {
        sendLog(data.toString(), 'log');
    });

    buildProcess.stderr.on('data', (data) => {
        sendLog(data.toString(), 'error');
    });

    buildProcess.on('close', (code) => {
        if (code === 0) {
            let fileName = 'app-release.apk';
            if (platform === 'ios') {
                const iosDir = path.join(builderDir, 'completed_builds', buildId);
                const ipaPath = path.join(iosDir, 'Runner.ipa');
                const xcarchivePath = path.join(iosDir, 'Runner.xcarchive');

                if (fs.existsSync(ipaPath)) {
                    fileName = 'Runner.ipa';
                } else if (fs.existsSync(xcarchivePath)) {
                    fileName = 'Runner.xcarchive';
                } else {
                    sendLog('Build succeeded but no downloadable artifact was found.', 'error');
                    res.end();
                    return;
                }
            }

            const downloadUrl = `/builds/${buildId}/${fileName}`;
            sendLog(`Build completed successfully! 🎉`, 'success');
            res.write(`data: ${JSON.stringify({ message: downloadUrl, type: 'build_success', buildId, platform })}\n\n`);
        } else {
            sendLog(`Build failed with exit code ${code} ❌`, 'error');
        }
        res.end();
    });

    buildProcess.on('error', (err) => {
        sendLog(`Failed to start subprocess: ${err.message}`, 'error');
        res.end();
    });
});

app.listen(PORT, () => {
    console.log(`Server is running at http://localhost:${PORT}`);
});
