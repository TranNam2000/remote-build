document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('buildForm');
    const tokenInput = document.getElementById('gitToken');
    const fetchReposBtn = document.getElementById('fetchReposBtn');
    const repoSelectGroup = document.getElementById('repoSelectGroup');
    const repoSelect = document.getElementById('repoSelect');
    const buildBtn = document.getElementById('buildBtn');
    const terminal = document.getElementById('terminal');
    const statusBadge = document.getElementById('statusBadge');
    
    const tasksList = document.getElementById('tasksList');
    const refreshTasksBtn = document.getElementById('refreshTasksBtn');
    let tasksInterval = null;

    // --- Live log streaming ---
    let currentLogId = null;
    let currentEventSource = null;

    window.viewBuildLog = function(buildId) {
        if (currentLogId === buildId) return;
        stopLogStream();
        currentLogId = buildId;
        terminal.innerHTML = '';
        statusBadge.className = 'badge running';
        statusBadge.textContent = 'Live';
        loadTasks();
        startLogStream(buildId);
    };

    function stopLogStream() {
        if (currentEventSource) {
            try { currentEventSource.close(); } catch(e) {}
            currentEventSource = null;
        }
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        currentLogId = null;
    }

    let pollTimer = null;
    let logSeenCount = 0;

    function startLogStream(buildId) {
        logSeenCount = 0;
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        pollLogs(buildId);
        pollTimer = setInterval(() => pollLogs(buildId), 500);
    }

    function renderLogItem(log) {
        if (log.type === 'build_success') {
            const actionDiv = document.createElement('div');
            actionDiv.className = 'log-line log-success';
            actionDiv.style.cssText = 'padding:15px;margin-top:10px;background:rgba(35,134,54,0.1);border:1px solid var(--success);border-radius:8px;';
            const link = document.createElement('a');
            link.href = log.message;
            const fileName = log.message.split('/').pop() || 'file';
            const ext = fileName.split('.').pop().toUpperCase();
            link.textContent = `📥 Tải xuống (${ext})`;
            link.style.cssText = 'color:#fff;text-decoration:none;font-weight:bold;display:block;text-align:center;';
            actionDiv.appendChild(link);
            terminal.appendChild(actionDiv);
            terminal.scrollTop = terminal.scrollHeight;
        } else {
            const cleanMsg = (log.message || '').replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g, "");
            appendLog(cleanMsg, log.type === 'log' ? 'system' : log.type);
        }
    }

    async function pollLogs(buildId) {
        if (currentLogId !== buildId) { if (pollTimer) clearInterval(pollTimer); return; }
        try {
            const res = await fetch(`/api/logs-snapshot/${buildId}`);
            if (!res.ok) return;
            const data = await res.json();
            if (data.logs && data.logs.length > logSeenCount) {
                const newLogs = data.logs.slice(logSeenCount);
                for (const log of newLogs) {
                    logSeenCount++;
                    if (log.type === 'end') {
                        statusBadge.className = 'badge offline';
                        statusBadge.textContent = 'Idle';
                        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
                        return;
                    }
                    renderLogItem(log);
                }
            }
            if (data.finished) {
                statusBadge.className = 'badge offline';
                statusBadge.textContent = 'Idle';
                if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
            }
        } catch(e) {}
    }

    function autoViewRunningBuild(tasks) {
        const running = tasks.filter(t => t.status === 'running');
        const queued = tasks.filter(t => t.status === 'queued' || t.status === 'paused');
        const allActive = [...running, ...queued];

        if (!currentLogId && allActive.length > 0) {
            viewBuildLog(allActive[0].id);
        } else if (currentLogId && !tasks.find(t => t.id === currentLogId || t.buildId === currentLogId)) {
            if (allActive.length > 0) {
                viewBuildLog(allActive[0].id);
            }
        }
    }

    // --- Tasks panel ---
    function updateBuildButton(hasActive) {
        if (buildBtn.disabled) return;
        if (hasActive) {
            buildBtn.textContent = '➕ Thêm vào hàng đợi';
            buildBtn.classList.remove('primary');
            buildBtn.classList.add('queue-mode');
        } else {
            buildBtn.textContent = '🚀 Bắt đầu Build';
            buildBtn.classList.remove('queue-mode');
            buildBtn.classList.add('primary');
        }
    }

    async function loadTasks() {
        try {
            const res = await fetch('/api/tasks');
            const { tasks, active } = await res.json();
            updateBuildButton(active > 0);
            if (tasks.length === 0) {
                tasksList.innerHTML = '<p class="no-tasks">Không có build nào đang chạy.</p>';
                return;
            }
            const running = tasks.filter(t => t.status === 'running');
            const waiting = tasks.filter(t => t.status === 'queued' || t.status === 'paused');
            const summary = `<div class="queue-summary">🔄 Đang chạy: ${running.length} | ⏳ Hàng đợi: ${waiting.length} | 📋 Tổng: ${tasks.length}</div>`;

            let order = 0;
            const runningHtml = running.map(t => {
                order++;
                const repo = t.repoUrl.replace('https://github.com/', '').replace('.git', '');
                const icon = t.platform === 'android' ? '🤖' : '🍏';
                const viewing = currentLogId === t.id ? ' task-viewing' : '';
                return `
                    <div class="task-item task-running${viewing}" onclick="viewBuildLog('${t.id}')" style="cursor:pointer">
                        <div class="task-order">${order}</div>
                        <div class="task-info">
                            <div class="task-name">${icon} ${repo}</div>
                            <div class="task-detail">${t.branch} · ${t.elapsed}${viewing ? ' · 📺 Đang xem log' : ''}</div>
                        </div>
                        <span class="task-status running">🔄 Đang build</span>
                        <button class="btn-cancel" onclick="event.stopPropagation();cancelTask('${t.buildId || t.id}')">✕ Hủy</button>
                    </div>`;
            }).join('');

            const queuedHtml = waiting.map((t, i) => {
                order++;
                const repo = t.repoUrl.replace('https://github.com/', '').replace('.git', '');
                const icon = t.platform === 'android' ? '🤖' : '🍏';
                const isPaused = t.status === 'paused';
                const statusClass = isPaused ? 'paused' : 'queued';
                const statusLabel = isPaused ? '⏸️ Tạm dừng' : `⏳ #${t.position}`;
                const pauseBtn = isPaused
                    ? `<button class="btn-queue btn-resume" onclick="togglePause('${t.id}')" title="Tiếp tục">▶</button>`
                    : `<button class="btn-queue btn-pause" onclick="togglePause('${t.id}')" title="Tạm dừng">⏸</button>`;
                const moveUp = t.position > 1 ? `<button class="btn-queue btn-move" onclick="moveQueue('${t.id}','up')" title="Lên">▲</button>` : '';
                const moveDown = t.position < waiting.length ? `<button class="btn-queue btn-move" onclick="moveQueue('${t.id}','down')" title="Xuống">▼</button>` : '';
                const viewing = currentLogId === t.id ? ' task-viewing' : '';
                return `
                    <div class="task-item task-${statusClass}${viewing}" onclick="viewBuildLog('${t.id}')" style="cursor:pointer">
                        <div class="task-order">${order}</div>
                        <div class="task-info">
                            <div class="task-name">${icon} ${repo}</div>
                            <div class="task-detail">${t.branch} · ${isPaused ? 'Đã tạm dừng' : 'Chờ đến lượt'}${viewing ? ' · 📺 Đang xem log' : ''}</div>
                        </div>
                        <span class="task-status ${statusClass}">${statusLabel}</span>
                        <div class="task-actions" onclick="event.stopPropagation()">
                            ${moveUp}${moveDown}
                            ${pauseBtn}
                            <button class="btn-queue btn-remove" onclick="removeQueue('${t.id}')" title="Xóa">✕</button>
                        </div>
                    </div>`;
            }).join('');

            tasksList.innerHTML = summary + runningHtml + queuedHtml;
            autoViewRunningBuild(tasks);
        } catch (e) {
            console.error('loadTasks error:', e);
        }
    }

    window.cancelTask = async function(id) {
        if (!confirm('Bạn chắc chắn muốn hủy build này?')) return;
        try {
            const res = await fetch('/api/cancel', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id })
            });
            const data = await res.json();
            if (data.success) {
                appendLog('⛔ Build đã bị hủy.', 'error');
                loadTasks();
            } else {
                alert(data.error || 'Không thể hủy');
            }
        } catch (e) { alert('Lỗi: ' + e.message); }
    };

    window.togglePause = async function(id) {
        try {
            await fetch('/api/queue/pause', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }) });
            loadTasks();
        } catch (e) { alert('Lỗi: ' + e.message); }
    };

    window.moveQueue = async function(id, direction) {
        try {
            await fetch('/api/queue/move', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, direction }) });
            loadTasks();
        } catch (e) { alert('Lỗi: ' + e.message); }
    };

    window.removeQueue = async function(id) {
        if (!confirm('Xóa build này khỏi hàng đợi?')) return;
        try {
            const res = await fetch('/api/queue/remove', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }) });
            const data = await res.json();
            if (data.success) { appendLog('🗑️ Đã xóa build khỏi hàng đợi.', 'info'); loadTasks(); }
            else alert(data.error || 'Không thể xóa');
        } catch (e) { alert('Lỗi: ' + e.message); }
    };

    refreshTasksBtn.addEventListener('click', loadTasks);
    loadTasks();
    tasksInterval = setInterval(loadTasks, 2000);


    const appendLog = (message, type = 'system') => {
        const div = document.createElement('div');
        div.className = `log-line log-${type}`;
        div.textContent = `> ${message}`;
        terminal.appendChild(div);
        terminal.scrollTop = terminal.scrollHeight;
    };

    let allFetchedRepos = [];

    fetchReposBtn.addEventListener('click', async () => {
        const token = tokenInput.value.trim();
        if (!token) {
            alert('Vui lòng nhập GitHub Access Token trước để tải danh sách dự án.');
            return;
        }

        fetchReposBtn.disabled = true;
        fetchReposBtn.textContent = 'Đang tải...';

        try {
            const res = await fetch('/api/repos', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token })
            });

            const data = await res.json();
            if (!res.ok) throw new Error(data.error);

            allFetchedRepos = data.repos;
            repoSelect.innerHTML = '<option value="">-- Chọn một repository --</option>';
            data.repos.forEach(repo => {
                const opt = document.createElement('option');
                opt.value = repo.url;
                opt.dataset.fullName = repo.name;
                opt.textContent = `${repo.name} ${repo.private ? '(Private)' : ''}`;
                repoSelect.appendChild(opt);
            });

            repoSelectGroup.style.display = 'block';
            platformSelectGroup.style.display = 'none';
            appendLog(`Đã tải thành công ${data.repos.length} repositories từ GitHub.`, 'success');
            appendLog(`📱 Chọn repository và branch để bắt đầu.`, 'info');
        } catch (error) {
            alert(`Lỗi khi tải repos: ${error.message}`);
        } finally {
            fetchReposBtn.disabled = false;
            fetchReposBtn.textContent = 'Lấy Repos';
        }
    });

    const branchSelectGroup = document.getElementById('branchSelectGroup');
    const branchSelect = document.getElementById('branchSelect');
    const platformSelectGroup = document.getElementById('platformSelectGroup');
    const platformSelect = document.getElementById('platformSelect');
    const buildTypeGroup = document.getElementById('buildTypeGroup');
    const buildTypeSelect = document.getElementById('buildTypeSelect');
    const flavorGroup = document.getElementById('flavorGroup');
    const flavorSelect = document.getElementById('flavorSelect');
    let detectedProjectType = null;
    let detectedFlavors = [];
    let isMacOS = false;

    // Show/hide build type and flavor when platform changes
    platformSelect.addEventListener('change', () => {
        if (platformSelect.value === 'android') {
            buildTypeGroup.style.display = 'block';
            if (detectedFlavors.length > 0) {
                flavorGroup.style.display = 'block';
            }
        } else {
            buildTypeGroup.style.display = 'none';
            flavorGroup.style.display = 'none';
        }
    });

    // Reset platform/flavor/buildType groups
    function resetBuildOptions() {
        platformSelectGroup.style.display = 'none';
        platformSelect.value = '';
        buildTypeGroup.style.display = 'none';
        flavorGroup.style.display = 'none';
        flavorSelect.innerHTML = '';
        detectedFlavors = [];
        detectedProjectType = null;
    }

    // Populate flavor dropdown
    function populateFlavors(flavors) {
        flavorSelect.innerHTML = '';
        flavors.forEach(f => {
            const opt = document.createElement('option');
            opt.value = f;
            opt.textContent = f;
            flavorSelect.appendChild(opt);
        });
    }

    // Chạy detect và cập nhật platform + flavor
    async function detectAndShowOptions(repoUrl, branch, token) {
        try {
            appendLog(`🔍 Đang phát hiện loại project (branch: ${branch || 'default'})...`, 'info');
            const detectRes = await fetch('/api/detect', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ repoUrl, branch, token })
            });
            if (!detectRes.ok) return;
            const detectData = await detectRes.json();
            detectedProjectType = detectData.projectType;
            isMacOS = detectData.isMac;
            detectedFlavors = detectData.flavors || [];

            if (detectedFlavors.length > 0) {
                appendLog(`🎨 Môi trường build: ${detectedFlavors.join(', ')}`, 'success');
                populateFlavors(detectedFlavors);
            }

            if (detectedProjectType === 'flutter') {
                // Flutter → luôn cho chọn Android hoặc iOS
                appendLog(`📋 Flutter project — chọn platform build.`, 'success');
                platformSelect.innerHTML = `<option value="android">🤖 Android</option><option value="ios">🍏 iOS</option>`;
                platformSelectGroup.style.display = 'block';
                // Android là default → hiện build type + flavor ngay
                buildTypeGroup.style.display = 'block';
                if (detectedFlavors.length > 0) flavorGroup.style.display = 'block';
            } else if (detectedProjectType === 'android') {
                // Native Android → tự động chọn Android, không cần dropdown platform
                appendLog(`📋 Android project — tự động chọn platform Android.`, 'success');
                platformSelectGroup.style.display = 'none';
                platformSelect.innerHTML = `<option value="android">🤖 Android</option>`;
                platformSelect.value = 'android';
                // Hiện thẳng build type + flavor
                buildTypeGroup.style.display = 'block';
                if (detectedFlavors.length > 0) flavorGroup.style.display = 'block';
            } else if (detectedProjectType === 'ios') {
                // iOS only
                appendLog(`📋 iOS project.`, 'success');
                platformSelect.innerHTML = `<option value="ios">🍏 iOS</option>`;
                platformSelect.value = 'ios';
                platformSelectGroup.style.display = 'none';
                buildTypeGroup.style.display = 'none';
                flavorGroup.style.display = 'none';
            } else {
                appendLog(`⚠️ Không xác định được loại project.`, 'warn');
                platformSelect.innerHTML = `<option value="android">🤖 Android</option><option value="ios">🍏 iOS</option>`;
                platformSelectGroup.style.display = 'block';
            }
        } catch(err) {
            appendLog(`Lỗi detect: ${err.message}`, 'error');
        }
    }

    repoSelect.addEventListener('change', async (e) => {
        if (e.target.value) {
            const selectedOption = e.target.options[e.target.selectedIndex];
            const repoFullName = selectedOption.dataset.fullName;
            const token = tokenInput.value.trim();

            branchSelectGroup.style.display = 'none';
            branchSelect.innerHTML = '<option value="">-- Chọn một branch --</option>';
            resetBuildOptions();

            if (token && repoFullName) {
                try {
                    appendLog(`Đang tải branches...`, 'info');
                    const branchRes = await fetch('/api/branches', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ token, repoFullName })
                    });
                    if (!branchRes.ok) throw new Error('Không thể tải branch');
                    const data = await branchRes.json();
                    if (data.branches && data.branches.length > 0) {
                        data.branches.forEach(branch => {
                            const opt = document.createElement('option');
                            opt.value = branch;
                            opt.textContent = branch;
                            branchSelect.appendChild(opt);
                        });
                        branchSelectGroup.style.display = 'block';
                        appendLog(`Đã tải ${data.branches.length} branches. Hãy chọn branch để tiếp tục.`, 'success');
                    }
                } catch(err) {
                    appendLog(`Lỗi: ${err.message}`, 'error');
                }
            }
        }
    });

    branchSelect.addEventListener('change', async () => {
        const branch = branchSelect.value;
        const repoUrl = repoSelect.value;
        const token = tokenInput.value.trim();
        resetBuildOptions();
        if (!branch || !repoUrl) return;
        await detectAndShowOptions(repoUrl, branch, token);
    });

    form.addEventListener('submit', async (e) => {
        e.preventDefault();

        const repoUrl = repoSelect.value.trim();
        const branch = branchSelect.value.trim();
        const token = tokenInput.value.trim();
        if (!repoUrl) {
            alert('Vui lòng chọn một repository từ danh sách.');
            return;
        }

        // Get platform choice
        const platform = platformSelect.value;
        if (!platform) {
            alert('Vui lòng chọn platform (Android hoặc iOS)');
            return;
        }

        // Get build type and flavor for Android
        const lane = (platform === 'android') ? (buildTypeSelect.value === 'aab' ? 'bundle' : 'release') : '';
        const buildTypeLabel = (platform === 'android') ? (buildTypeSelect.value === 'aab' ? 'AAB' : 'APK') : '';
        const flavor = (platform === 'android' && detectedFlavors.length > 0) ? flavorSelect.value : '';

        buildBtn.disabled = true;
        buildBtn.textContent = 'Đang gửi...';
        setTimeout(() => { buildBtn.disabled = false; loadTasks(); }, 3000);

        stopLogStream();
        terminal.innerHTML = '';
        appendLog(`Bắt đầu yêu cầu build`, 'info');
        appendLog(`Repository: ${repoUrl}`, 'info');
        if (branch) appendLog(`Branch: ${branch}`, 'info');
        appendLog(`Platform: ${platform.toUpperCase()}${buildTypeLabel ? ' (' + buildTypeLabel + ')' : ''}${flavor ? ' [' + flavor + ']' : ''}`, 'info');

        try {
            const response = await fetch('/api/build', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ repoUrl, branch, token, platform, lane, flavor })
            });
            const data = await response.json();

            if (!response.ok) {
                appendLog(`Error: ${data.error}`, 'error');
            } else if (data.queued) {
                appendLog(`⏳ Đã thêm vào hàng đợi — Vị trí #${data.position}`, 'info');
                viewBuildLog(data.queueId);
            } else {
                appendLog(`✅ Build bắt đầu ngay!`, 'success');
                viewBuildLog(data.queueId);
            }
        } catch (error) {
            appendLog(`Yêu cầu thất bại: ${error.message}`, 'error');
        }
        loadTasks();
    });
});

function appendLog(message, type = 'system') {
    const terminal = document.getElementById('terminal');
    const div = document.createElement('div');
    div.className = `log-line log-${type}`;
    // Use innerHTML but escapes HTML to prevent XSS while allowing structured spacing
    const safeText = document.createTextNode(message);
    div.appendChild(safeText);
    terminal.appendChild(div);
    terminal.scrollTop = terminal.scrollHeight;
}
