document.addEventListener('DOMContentLoaded', () => {
    // === Global Application State & DOM Elements ===
    const state = {
        currentUser: null,
        timerInterval: null,
        startTime: null,
        totalSeconds: 0,
        gameMode: 'NUMBERS',
        imageUrl: null,
        isDaily: false,
    };

    const DOMElements = {
        authScreen: document.getElementById('auth-screen'), settingsScreen: document.getElementById('settings-screen'), gameScreen: document.getElementById('game-screen'), leaderboardScreen: document.getElementById('leaderboard-screen'),
        navMenu: document.getElementById('nav-menu'), navButtons: document.querySelectorAll('.nav-btn'), userStatus: document.getElementById('user-status'), welcomeMessage: document.getElementById('welcome-message'), logoutBtn: document.getElementById('logout-btn'),
        loginView: document.getElementById('login-view'), registerView: document.getElementById('register-view'), loginForm: document.getElementById('login-form'), registerForm: document.getElementById('register-form'),
        loginBtn: document.getElementById('login-btn'), registerBtn: document.getElementById('register-btn'), guestBtn: document.getElementById('guest-btn'),
        showRegisterLink: document.getElementById('show-register-link'), showLoginLink: document.getElementById('show-login-link'), authError: document.getElementById('auth-error'),
        startBtn: document.getElementById('start-btn'), boardSizeSelect: document.getElementById('board-size'), difficultySelect: document.getElementById('difficulty'),
        dailyCheck: document.getElementById('daily-challenge-check'), regularSettings: document.getElementById('regular-settings'), modeRadios: document.querySelectorAll('input[name="game-mode"]'),
        imageSelection: document.getElementById('image-selection'), previewImages: document.querySelectorAll('.preview-img'), imageUpload: document.getElementById('image-upload'), customImageName: document.getElementById('custom-image-name'),
        gameBoard: document.getElementById('game-board'), movesCounter: document.getElementById('moves-counter'), timerDisplay: document.getElementById('timer'),
        activeGameView: document.getElementById('active-game-view'), gameControls: document.getElementById('game-controls'), hintBtn: document.getElementById('hint-btn'),
        undoBtn: document.getElementById('undo-btn'), redoBtn: document.getElementById('redo-btn'), abandonBtn: document.getElementById('abandon-btn'),
        winOverlay: document.getElementById('win-overlay'), winStars: document.getElementById('win-stars'), winMoves: document.getElementById('win-moves'), winTime: document.getElementById('win-time'), playAgainBtn: document.getElementById('play-again-btn'),
        leaderboardTables: document.getElementById('leaderboard-tables'), filterSize: document.getElementById('filter-size'), filterDifficulty: document.getElementById('filter-difficulty'), applyFiltersBtn: document.getElementById('apply-filters-btn'),
    };

    // === API Module: Simplified with a single action endpoint ===
    const api = {
        async call(endpoint, options = {}) {
            try {
                const response = await fetch(endpoint, options);
                if (!response.ok) {
                    const errorData = await response.json().catch(() => ({ message: `HTTP error! status: ${response.status}` }));
                    throw new Error(errorData.message);
                }
                const contentType = response.headers.get("content-type");
                if (contentType && contentType.includes("application/json")) return response.json();
                return response.text();
            } catch (error) {
                console.error(`API call to ${endpoint} failed:`, error);
                if (DOMElements.authScreen.classList.contains('active')) { DOMElements.authError.textContent = error.message; } else { alert(`An error occurred: ${error.message}`); }
            }
        },
        performAction: (action, params = {}) => api.call('/api/action', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action, params }),
        }),
        // Auth and upload remain separate
        register: (username, passwordHash) => api.call('/api/auth/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, passwordHash }) }),
        login: (username, passwordHash) => api.call('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, passwordHash }) }),
        loginAsGuest: () => api.call('/api/auth/guest', { method: 'POST' }),
        logout: () => api.call('/api/auth/logout', { method: 'POST' }),
        getStatus: () => api.call('/api/auth/status'),
        uploadImage: (formData) => api.call('/api/upload-image', { method: 'POST', body: formData }),
    };

    // === Auth Module: Handles login, registration, etc. ===
    const auth = {
        hashPassword: (password) => CryptoJS.SHA256(password).toString(CryptoJS.enc.Hex).toUpperCase(),
        handleLogin: async (event) => { event.preventDefault(); const username = document.getElementById('login-username').value.trim(); const password = document.getElementById('login-password').value; if (!username || !password) return; const response = await api.login(username, auth.hashPassword(password)); if (response && response.success) auth.onLoginSuccess(response.user); },
        handleRegister: async (event) => { event.preventDefault(); const username = document.getElementById('register-username').value.trim(); const password = document.getElementById('register-password').value; if (!username || !password) return; const response = await api.register(username, auth.hashPassword(password)); if (response && response.success) auth.onLoginSuccess(response.user); },
        handleGuest: async () => { const response = await api.loginAsGuest(); if (response && response.success) auth.onLoginSuccess(response.user); },
        handleLogout: async () => { await api.logout(); state.currentUser = null; ui.updateLoginState(); DOMElements.loginView.classList.remove('hidden'); DOMElements.registerView.classList.add('hidden'); ui.showScreen('auth'); },
        onLoginSuccess: (userData) => { state.currentUser = userData; ui.updateLoginState(); ui.showScreen('settings'); DOMElements.authError.textContent = ''; document.querySelectorAll('#auth-screen form').forEach(f => f.reset()); },
        checkStatus: async () => { const response = await api.getStatus(); if (response && response.isLoggedIn) { auth.onLoginSuccess(response.user); } else { ui.showScreen('auth'); } }
    };

    // === Game Logic Module: Uses the simplified API ===
    const game = {
        start: async (forceNew = false) => {
            const size = parseInt(DOMElements.boardSizeSelect.value, 10);
            const settings = { isDailyChallenge: state.isDaily, gameMode: state.gameMode, imageUrl: state.imageUrl, size: size, difficulty: parseInt(DOMElements.difficultySelect.value, 10), forceNew: forceNew };
            const gameState = await api.performAction('start', settings);

            if (gameState && gameState.active_session_found) {
                if (confirm('У вас есть незаконченная игра. Хотите продолжить?')) {
                    DOMElements.activeGameView.classList.remove('hidden');
                    DOMElements.winOverlay.classList.add('hidden');
                    ui.showScreen('game');
                    ui.render(gameState);
                    timer.start(gameState.startTime, gameState.boardSize);
                } else {
                    game.start(true);
                }
                return;
            }
            if (gameState && gameState.sessionId) {
                DOMElements.activeGameView.classList.remove('hidden');
                DOMElements.winOverlay.classList.add('hidden');
                ui.showScreen('game');
                ui.render(gameState);
                timer.start(gameState.startTime, size);
            }
        },
        move: async (tileValue) => { const gameState = await api.performAction('move', { tile: tileValue }); if (gameState) ui.render(gameState); },
        undo: async () => { const gameState = await api.performAction('undo'); if (gameState) ui.render(gameState); },
        redo: async () => { const gameState = await api.performAction('redo'); if (gameState) ui.render(gameState); },
        abandon: async () => { await api.performAction('abandon'); timer.stop(); ui.showScreen('settings'); },
        playAgain: () => { timer.stop(); ui.showScreen('settings'); },
        hint: async () => { const data = await api.performAction('hint'); if(data && data.hint) { ui.highlightHint(data.hint); } }
    };
    
    // === UI Module: Handles all DOM manipulation ===
    const ui = {
        showScreen: (screenName) => {
            document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
            const screen = document.getElementById(`${screenName}-screen`); if(screen) screen.classList.add('active');
            if (state.currentUser) { DOMElements.navButtons.forEach(btn => { btn.classList.toggle('active', btn.dataset.screen === screenName); }); }
            if (screenName === 'leaderboard') { ui.renderLeaderboards(); }
        },
        updateLoginState: () => { const isLoggedIn = !!state.currentUser; DOMElements.userStatus.classList.toggle('hidden', !isLoggedIn); DOMElements.navMenu.classList.toggle('hidden', !isLoggedIn); if (isLoggedIn) { DOMElements.welcomeMessage.textContent = `Добро пожаловать, ${state.currentUser.name}!`; } },
        render: (gameState) => {
            const { boardSize, boardState, moves, status, imageUrl, stars } = gameState;
            DOMElements.movesCounter.textContent = moves;

            if (status === 'SOLVED') {
                timer.stop();
                DOMElements.winMoves.textContent = moves;
                const timeElapsed = Math.floor((new Date() - state.startTime) / 1000);
                const minutes = String(Math.floor(timeElapsed / 60)).padStart(2, '0');
                const seconds = String(timeElapsed % 60).padStart(2, '0');
                DOMElements.winTime.textContent = `${minutes}:${seconds}`;
                DOMElements.winStars.innerHTML = (stars > 0) ? '★'.repeat(stars) + '☆'.repeat(3 - stars) : 'Решено';
                DOMElements.activeGameView.classList.add('hidden');
                DOMElements.winOverlay.classList.remove('hidden');
            } else {
                DOMElements.activeGameView.classList.remove('hidden');
                DOMElements.winOverlay.classList.add('hidden');
                document.documentElement.style.setProperty('--board-size', boardSize);
                DOMElements.gameBoard.innerHTML = '';
                boardState.forEach(value => {
                    const tile = document.createElement('div'); tile.classList.add('tile');
                    if (value === 0) { tile.classList.add('empty'); } 
                    else {
                        tile.dataset.value = value;
                        if (state.gameMode === 'IMAGE' && imageUrl) {
                            const col = (value - 1) % boardSize; const row = Math.floor((value - 1) / boardSize);
                            tile.style.backgroundImage = `url(${imageUrl})`;
                            tile.style.backgroundPosition = `${(col * 100) / (boardSize - 1)}% ${(row * 100) / (boardSize - 1)}%`;
                        } else { tile.textContent = value; }
                    }
                    DOMElements.gameBoard.appendChild(tile);
                });
            }
        },
        renderLeaderboards: async () => {
            const size = DOMElements.filterSize.value;
            const difficulty = DOMElements.filterDifficulty.value;
            const data = await api.performAction('get_leaderboards', { size: size, difficulty: difficulty });
            DOMElements.leaderboardTables.innerHTML = '';
            if(!data || !data.leaderboard) { DOMElements.leaderboardTables.innerHTML = '<p>Пока нет данных.</p>'; return; }
            const createTable = (title, headers, rows, columns) => {
                const container = document.createElement('div');
                const h3 = document.createElement('h3'); h3.textContent = title; container.appendChild(h3);
                if(!rows || rows.length === 0) { const p = document.createElement('p'); p.textContent = 'Для выбранных фильтров нет данных.'; container.appendChild(p); return container; }
                const table = document.createElement('table'); const thead = document.createElement('thead'); const tbody = document.createElement('tbody');
                thead.innerHTML = `<tr>${headers.map(h => `<th>${h}</th>`).join('')}</tr>`;
                rows.forEach(row => { const tr = document.createElement('tr'); tr.innerHTML = columns.map(col => `<td>${row[col] !== undefined ? row[col] : ''}</td>`).join(''); tbody.appendChild(tr); });
                table.appendChild(thead); table.appendChild(tbody); container.appendChild(table);
                return container;
            };
            DOMElements.leaderboardTables.appendChild(createTable('Топ игроков по звездам', ['Игрок', 'Всего звёзд'], data.leaderboard, ['user', 'total_stars']));
        },
        highlightHint: (tileValue) => { const tile = DOMElements.gameBoard.querySelector(`[data-value="${tileValue}"]`); if (tile) { tile.classList.add('hint'); setTimeout(() => tile.classList.remove('hint'), 1000); } },
    };
    
    // === Timer Module ===
    const timer = {
        start: (startTimeString, boardSize) => {
            timer.stop(); state.startTime = new Date(startTimeString);
            const totalMinutes = Math.ceil(10 * (boardSize / 4));
            state.totalSeconds = totalMinutes * 60;
            state.timerInterval = setInterval(() => {
                const timeElapsed = Math.floor((new Date() - state.startTime) / 1000);
                const timeRemaining = state.totalSeconds - timeElapsed;
                if (timeRemaining <= 0) {
                    DOMElements.timerDisplay.textContent = '00:00';
                    timer.stop();
                    alert('Время вышло!');
                    game.abandon();
                    return;
                }
                const minutes = String(Math.floor(timeRemaining / 60)).padStart(2, '0');
                const seconds = String(timeRemaining % 60).padStart(2, '0');
                DOMElements.timerDisplay.textContent = `${minutes}:${seconds}`;
            }, 1000);
        },
        stop: () => { if (state.timerInterval) clearInterval(state.timerInterval); state.timerInterval = null; }
    };

    // === Initializer: Assigns all event listeners ===
    function init() {
        DOMElements.loginForm.addEventListener('submit', auth.handleLogin);
        DOMElements.registerForm.addEventListener('submit', auth.handleRegister);
        DOMElements.guestBtn.addEventListener('click', auth.handleGuest);
        DOMElements.logoutBtn.addEventListener('click', auth.handleLogout);
        DOMElements.showRegisterLink.addEventListener('click', (e) => { e.preventDefault(); DOMElements.loginView.classList.add('hidden'); DOMElements.registerView.classList.remove('hidden'); DOMElements.authError.textContent = ''; });
        DOMElements.showLoginLink.addEventListener('click', (e) => { e.preventDefault(); DOMElements.loginView.classList.remove('hidden'); DOMElements.registerView.classList.add('hidden'); DOMElements.authError.textContent = ''; });
        DOMElements.navButtons.forEach(btn => btn.addEventListener('click', () => ui.showScreen(btn.dataset.screen)));
        DOMElements.dailyCheck.addEventListener('change', (e) => { state.isDaily = e.target.checked; DOMElements.regularSettings.classList.toggle('hidden', state.isDaily); });
        DOMElements.modeRadios.forEach(radio => radio.addEventListener('change', (e) => { state.gameMode = e.target.value; DOMElements.imageSelection.classList.toggle('hidden', state.gameMode !== 'IMAGE'); }));
        DOMElements.previewImages.forEach(img => img.addEventListener('click', (e) => { DOMElements.previewImages.forEach(i => i.classList.remove('selected')); e.target.classList.add('selected'); state.imageUrl = e.target.dataset.src; DOMElements.customImageName.textContent = ''; DOMElements.imageUpload.value = ''; }));
        DOMElements.imageUpload.addEventListener('change', async (e) => {
            const file = e.target.files[0]; if (!file) return;
            const formData = new FormData(); formData.append('image', file);
            const res = await api.uploadImage(formData);
            if (res && res.imageUrl) { state.imageUrl = res.imageUrl; DOMElements.customImageName.textContent = `Загружено: ${file.name}`; DOMElements.previewImages.forEach(i => i.classList.remove('selected')); }
        });
        DOMElements.startBtn.addEventListener('click', () => game.start(false));
        DOMElements.gameBoard.addEventListener('click', (e) => { const tile = e.target.closest('.tile'); if (tile && tile.dataset.value) game.move(parseInt(tile.dataset.value, 10)); });
        DOMElements.hintBtn.addEventListener('click', game.hint);
        DOMElements.undoBtn.addEventListener('click', game.undo);
        DOMElements.redoBtn.addEventListener('click', game.redo);
        DOMElements.abandonBtn.addEventListener('click', game.abandon);
        DOMElements.playAgainBtn.addEventListener('click', game.playAgain);
        DOMElements.applyFiltersBtn.addEventListener('click', ui.renderLeaderboards);
        document.addEventListener('keydown', (e) => {
            if(DOMElements.gameScreen.classList.contains('active')) {
                if(e.key.toLowerCase() === 'h') game.hint();
                if(e.key.toLowerCase() === 'u' && !e.shiftKey) { e.preventDefault(); game.undo(); }
                if(e.key.toLowerCase() === 'u' && e.shiftKey) { e.preventDefault(); game.redo(); }
            }
        });
        auth.checkStatus();
    }
    init();
});