document.addEventListener('DOMContentLoaded', () => {
    const platformCards = document.querySelectorAll('.platform-card');
    const form = document.getElementById('buildForm');
    const tokenInput = document.getElementById('gitToken');
    const fetchReposBtn = document.getElementById('fetchReposBtn');
    const repoSelectGroup = document.getElementById('repoSelectGroup');
    const repoSelect = document.getElementById('repoSelect');
    const buildBtn = document.getElementById('buildBtn');
    const terminal = document.getElementById('terminal');
    const statusBadge = document.getElementById('statusBadge');
    const cancelBuildBtn = document.getElementById('cancelBuildBtn');
    const historyList = document.getElementById('historyList');
    const refreshHistoryBtn = document.getElementById('refreshHistoryBtn');
    
    let selectedPlatform = 'android';
    let currentBuildId = null;

    platformCards.forEach(card => {
        card.addEventListener('click', () => {
            platformCards.forEach(c => c.classList.remove('active'));
            card.classList.add('active');
            selectedPlatform = card.getAttribute('data-platform');
        });
    });

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
            appendLog(`Đã tải thành công ${data.repos.length} repositories từ GitHub.`, 'success');
        } catch (error) {
            alert(`Lỗi khi tải repos: ${error.message}`);
        } finally {
            fetchReposBtn.disabled = false;
            fetchReposBtn.textContent = 'Lấy Repos';
        }
    });

    const branchSelectGroup = document.getElementById('branchSelectGroup');
    const branchSelect = document.getElementById('branchSelect');

    repoSelect.addEventListener('change', async (e) => {
        if (e.target.value) {
            const selectedOption = e.target.options[e.target.selectedIndex];
            const repoFullName = selectedOption.dataset.fullName;
            const token = tokenInput.value.trim();
            
            branchSelectGroup.style.display = 'none';
            branchSelect.innerHTML = '<option value="">-- Chọn một branch --</option>';

            if (token && repoFullName) {
                try {
                    appendLog(`Đang tải danh sách nhánh (branches) cho ${repoFullName}...`, 'info');
                    const res = await fetch('/api/branches', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ token, repoFullName })
                    });
                    
                    if (res.ok) {
                        const data = await res.json();
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
                } catch(err) {
                    appendLog(`Lỗi tải branches: ${err.message}`, 'error');
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

        buildBtn.disabled = true;
        buildBtn.textContent = 'Đang Build...';
        statusBadge.className = 'badge running';
        statusBadge.textContent = 'Running';
        terminal.innerHTML = '';
        cancelBuildBtn.disabled = false;
        currentBuildId = null;
        
        appendLog(`Bắt đầu yêu cầu build cho ${selectedPlatform.toUpperCase()}`, 'info');
        appendLog(`Repository: ${repoUrl}`, 'info');
        if (branch) appendLog(`Branch: ${branch}`, 'info');
        

        try {
            const response = await fetch('/api/build', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ platform: selectedPlatform, repoUrl, branch, token })
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
                                if (data.buildId && !currentBuildId) {
                                    currentBuildId = data.buildId;
                                    appendLog(`Build ID: ${currentBuildId}`, 'system');
                                }
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
                                    fetchHistory();
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
            cancelBuildBtn.disabled = true;
            currentBuildId = null;
            appendLog('--- Kết thúc phiên ---', 'system');
            fetchHistory();
        }
    });

    const renderHistory = (builds) => {
        historyList.innerHTML = '';
        if (!builds || builds.length === 0) {
            historyList.textContent = 'Chưa có lịch sử build.';
            return;
        }

        builds.forEach((b) => {
            const item = document.createElement('div');
            item.className = 'history-item';

            const meta = document.createElement('div');
            meta.className = 'history-meta';
            const title = document.createElement('div');
            title.textContent = `${b.platform.toUpperCase()} • ${b.id}`;
            const sub = document.createElement('div');
            sub.textContent = `Repo: ${b.repoUrl}${b.branch ? ` | Branch: ${b.branch}` : ''}`;
            meta.appendChild(title);
            meta.appendChild(sub);

            const actions = document.createElement('div');
            actions.className = 'history-actions';
            const status = document.createElement('span');
            status.className = `status-pill status-${b.status}`;
            status.textContent = b.status;
            actions.appendChild(status);

            if (b.downloadUrl) {
                const link = document.createElement('a');
                link.href = b.downloadUrl;
                link.textContent = 'Tải xuống';
                link.style.color = '#fff';
                link.style.textDecoration = 'none';
                link.style.fontWeight = '600';
                actions.appendChild(link);
            }

            if (b.status === 'pending' || b.status === 'running') {
                const cancelBtn = document.createElement('button');
                cancelBtn.className = 'btn secondary';
                cancelBtn.style.width = 'auto';
                cancelBtn.style.padding = '4px 10px';
                cancelBtn.style.fontSize = '0.8rem';
                cancelBtn.textContent = 'Hủy';
                cancelBtn.addEventListener('click', async () => {
                    await fetch(`/api/builds/${b.id}/cancel`, { method: 'POST' });
                    fetchHistory();
                });
                actions.appendChild(cancelBtn);
            }

            item.appendChild(meta);
            item.appendChild(actions);
            historyList.appendChild(item);
        });
    };

    const fetchHistory = async () => {
        try {
            const res = await fetch('/api/builds');
            const data = await res.json();
            renderHistory(data.builds || []);
        } catch (e) {
            historyList.textContent = 'Không thể tải lịch sử build.';
        }
    };

    refreshHistoryBtn.addEventListener('click', fetchHistory);
    cancelBuildBtn.addEventListener('click', async () => {
        if (!currentBuildId) return;
        await fetch(`/api/builds/${currentBuildId}/cancel`, { method: 'POST' });
        fetchHistory();
    });

    fetchHistory();
    setInterval(fetchHistory, 10000);
});
