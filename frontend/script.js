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

    // --- Tasks panel ---
    async function loadTasks() {
        try {
            const res = await fetch('/api/tasks');
            const { tasks } = await res.json();
            if (tasks.length === 0) {
                tasksList.innerHTML = '<p class="no-tasks">Không có build nào đang chạy.</p>';
                return;
            }
            tasksList.innerHTML = tasks.map(t => {
                const repo = t.repoUrl.replace('https://github.com/', '').replace('.git', '');
                const detail = t.status === 'running'
                    ? `${t.branch} · ${t.elapsed}`
                    : `${t.branch} · Hàng đợi #${t.position}`;
                return `
                    <div class="task-item">
                        <div class="task-info">
                            <div class="task-name">${t.platform === 'android' ? '🤖' : '🍏'} ${repo}</div>
                            <div class="task-detail">${detail}</div>
                        </div>
                        <span class="task-status ${t.status}">${t.status === 'running' ? '🔄 Running' : '⏳ Queued'}</span>
                        <button class="btn-cancel" onclick="cancelTask('${t.id}')">✕ Hủy</button>
                    </div>`;
            }).join('');
        } catch {}
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
            platformSelectGroup.style.display = 'block';  // Show platform selection after repos load
            appendLog(`Đã tải thành công ${data.repos.length} repositories từ GitHub.`, 'success');
            appendLog(`📱 Chọn platform build trước, rồi chọn repository.`, 'info');
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

    repoSelect.addEventListener('change', async (e) => {
        if (e.target.value) {
            const selectedOption = e.target.options[e.target.selectedIndex];
            const repoFullName = selectedOption.dataset.fullName;
            const token = tokenInput.value.trim();

            branchSelectGroup.style.display = 'none';
            branchSelect.innerHTML = '<option value="">-- Chọn một branch --</option>';
            flavorGroup.style.display = 'none';
            detectedFlavors = [];

            if (token && repoFullName) {
                try {
                    // Fetch branches and detect project type in parallel
                    appendLog(`Đang tải branches và phát hiện loại project...`, 'info');

                    const [branchRes, detectRes] = await Promise.all([
                        fetch('/api/branches', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ token, repoFullName })
                        }),
                        fetch('/api/detect', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ repoUrl: e.target.value, branch: '' })
                        })
                    ]);

                    if (branchRes.ok) {
                        const data = await branchRes.json();
                        if (data.branches && data.branches.length > 0) {
                            data.branches.forEach(branch => {
                                const opt = document.createElement('option');
                                opt.value = branch;
                                opt.textContent = branch;
                                branchSelect.appendChild(opt);
                            });
                            branchSelectGroup.style.display = 'block';
                            appendLog(`Đã tải ${data.branches.length} branches.`, 'success');
                        }
                    } else {
                        throw new Error('Không thể tải branch');
                    }

                    if (detectRes.ok) {
                        const detectData = await detectRes.json();
                        detectedProjectType = detectData.projectType;
                        isMacOS = detectData.isMac;
                        detectedFlavors = detectData.flavors || [];

                        appendLog(`📋 Project Type: ${detectedProjectType}`, 'success');

                        if (detectedFlavors.length > 0) {
                            appendLog(`🎨 Flavors detected: ${detectedFlavors.join(', ')}`, 'success');
                            flavorSelect.innerHTML = '';
                            detectedFlavors.forEach(f => {
                                const opt = document.createElement('option');
                                opt.value = f;
                                opt.textContent = f;
                                flavorSelect.appendChild(opt);
                            });
                            // Show flavor dropdown if Android is selected
                            if (platformSelect.value === 'android') {
                                flavorGroup.style.display = 'block';
                            }
                        }
                    }
                } catch(err) {
                    appendLog(`Lỗi: ${err.message}`, 'error');
                }
            }
        }
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
        buildBtn.textContent = 'Đang Build...';
        statusBadge.className = 'badge running';
        statusBadge.textContent = 'Running';
        terminal.innerHTML = '';

        appendLog(`Bắt đầu yêu cầu build`, 'info');
        appendLog(`Repository: ${repoUrl}`, 'info');
        if (branch) appendLog(`Branch: ${branch}`, 'info');
        appendLog(`Platform: ${platform.toUpperCase()}${buildTypeLabel ? ' (' + buildTypeLabel + ')' : ''}${flavor ? ' [' + flavor + ']' : ''}`, 'info');

        try {
            const response = await fetch('/api/build', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ repoUrl, branch, token, platform, lane, flavor })
            });

            if (!response.ok) {
                const errorData = await response.json();
                appendLog(`Error: ${errorData.error}`, 'error');
                throw new Error(errorData.error);
            }

            const reader = response.body.getReader();
            const decoder = new TextDecoder('utf-8');
            let done = false;

            while (!done) {
                const { value, done: readerDone } = await reader.read();
                done = readerDone;
                if (value) {
                    const chunk = decoder.decode(value);
                    const lines = chunk.split('\n\n');
                    for (const line of lines) {
                        if (line.startsWith('data: ')) {
                            try {
                                const data = JSON.parse(line.substring(6));
                                if (data.type === 'build_success') {
                                    const actionDiv = document.createElement('div');
                                    actionDiv.className = 'log-line log-success';
                                    actionDiv.style.padding = '15px';
                                    actionDiv.style.marginTop = '10px';
                                    actionDiv.style.backgroundColor = 'rgba(35, 134, 54, 0.1)';
                                    actionDiv.style.border = '1px solid var(--success)';
                                    actionDiv.style.borderRadius = '8px';
                                    
                                    const link = document.createElement('a');
                                    link.href = data.message;
                                    link.textContent = `📥 Tải xuống kết quả build (${data.platform.toUpperCase()})`;
                                    link.style.color = '#fff';
                                    link.style.textDecoration = 'none';
                                    link.style.fontWeight = 'bold';
                                    link.style.display = 'block';
                                    link.style.textAlign = 'center';
                                    
                                    actionDiv.appendChild(link);
                                    terminal.appendChild(actionDiv);
                                } else {
                                    appendLog(data.message, data.type === 'log' ? 'system' : data.type);
                                }
                            } catch (err) {
                                // Incomplete JSON chunk potentially, ignore or buffer
                                console.error('Error parsing SSE data:', err);
                            }
                        }
                    }
                }
            }

        } catch (error) {
            appendLog(`Yêu cầu thất bại: ${error.message}`, 'error');
        } finally {
            buildBtn.disabled = false;
            buildBtn.textContent = 'Bắt đầu Build';
            statusBadge.className = 'badge offline';
            statusBadge.textContent = 'Idle';
            appendLog('--- Kết thúc phiên ---', 'system');
        }
    });
});
