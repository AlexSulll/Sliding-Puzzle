document.addEventListener('DOMContentLoaded', () => {
    // === Global Application State & DOM Elements ===
    const state = {
        currentUser: null,
        timerInterval: null,
        startTime: null,
        totalSeconds: 0,
        // --- ИЗМЕНЕНО 1: Начальное состояние теперь 'INTS' ---
        gameMode: 'INTS',
        imageUrl: null,
        isDaily: false,
    };

    const DOMElements = {
        authScreen: document.getElementById('auth-screen'),
        settingsScreen: document.getElementById('settings-screen'),
        gameScreen: document.getElementById('game-screen'),
        leaderboardScreen: document.getElementById('leaderboard-screen'),
        historyScreen: document.getElementById('history-screen'),
        navMenu: document.getElementById('nav-menu'),
        navButtons: document.querySelectorAll('.nav-btn'),
        userStatus: document.getElementById('user-status'),
        welcomeMessage: document.getElementById('welcome-message'),
        logoutBtn: document.getElementById('logout-btn'),
        loginView: document.getElementById('login-view'),
        registerView: document.getElementById('register-view'),
        loginForm: document.getElementById('login-form'),
        registerForm: document.getElementById('register-form'),
        loginBtn: document.getElementById('login-btn'),
        registerBtn: document.getElementById('register-btn'),
        showRegisterLink: document.getElementById('show-register-link'),
        showLoginLink: document.getElementById('show-login-link'),
        authError: document.getElementById('auth-error'),
        startBtn: document.getElementById('start-btn'),
        boardSizeSelect: document.getElementById('board-size'),
        difficultySelect: document.getElementById('difficulty'),
        dailyCheck: document.getElementById('daily-challenge-check'),
        regularSettings: document.getElementById('regular-settings'),
        modeRadios: document.querySelectorAll('input[name="game-mode"]'),
        imageSelection: document.getElementById('image-selection'),
        userImagePreviews: document.getElementById('user-image-previews'),
        defaultImagePreviews: document.getElementById('default-image-previews'),
        imageUpload: document.getElementById('image-upload'),
        uploadLabel: document.querySelector('label[for="image-upload"]'),
        customImageName: document.getElementById('custom-image-name'),
        gameBoard: document.getElementById('game-board'),
        movesCounter: document.getElementById('moves-counter'),
        timerDisplay: document.getElementById('timer'),
        activeGameView: document.getElementById('active-game-view'),
        gameControls: document.getElementById('game-controls'),
        hintBtn: document.getElementById('hint-btn'),
        undoBtn: document.getElementById('undo-btn'),
        redoBtn: document.getElementById('redo-btn'),
        abandonBtn: document.getElementById('abandon-btn'),
        winOverlay: document.getElementById('win-overlay'),
        winStars: document.getElementById('win-stars'),
        winMoves: document.getElementById('win-moves'),
        winTime: document.getElementById('win-time'),
        playAgainBtn: document.getElementById('play-again-btn'),
        leaderboardTables: document.getElementById('leaderboard-tables'),
        filterSize: document.getElementById('filter-size'),
        filterDifficulty: document.getElementById('filter-difficulty'),
        applyFiltersBtn: document.getElementById('apply-filters-btn'),
        historyScreen: document.getElementById('history-screen'),
        historyTableContainer: document.getElementById('history-table-container')
    };

    // === API Module: Simplified with a single action endpoint ===
    const api = {
        async call(endpoint, options = {}) {
            try {
                const response = await fetch(endpoint, options);
                if (!response.ok) {
                    const errorData = await response.json().catch(() => ({ message: `HTTP error! status: ${response.status}` }));
                    throw new Error(errorData.message || `HTTP error! status: ${response.status}`);
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
        register: (username, passwordHash) => api.call('/api/auth/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, passwordHash }) }),
        login: (username, passwordHash) => api.call('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, passwordHash }) }),
        logout: () => api.call('/api/auth/logout', { method: 'POST' }),
        getStatus: () => api.call('/api/auth/status'),
        uploadImage: (formData) => api.call('/api/upload-image', { method: 'POST', body: formData }),
    };

    // === Auth Module: Handles login, registration, etc. ===
    const auth = {
        hashPassword: (password) => CryptoJS.SHA256(password).toString(CryptoJS.enc.Hex).toUpperCase(),
        handleLogin: async (event) => { event.preventDefault(); const username = document.getElementById('login-username').value.trim(); const password = document.getElementById('login-password').value; if (!username || !password) return; const response = await api.login(username, auth.hashPassword(password)); if (response && response.success) auth.onLoginSuccess(response.user); },
        handleRegister: async (event) => { event.preventDefault(); const username = document.getElementById('register-username').value.trim(); const password = document.getElementById('register-password').value; if (!username || !password) return; const response = await api.register(username, auth.hashPassword(password)); if (response && response.success) auth.onLoginSuccess(response.user); },
        handleLogout: async () => { await api.logout(); state.currentUser = null; ui.updateLoginState(); DOMElements.loginView.classList.remove('hidden'); DOMElements.registerView.classList.add('hidden'); ui.showScreen('auth'); },
        onLoginSuccess: (userData) => {
            state.currentUser = userData;
            ui.loadImages();
            ui.updateLoginState();
            ui.showScreen('settings');
            DOMElements.authError.textContent = '';
            document.querySelectorAll('#auth-screen form').forEach(f => f.reset());
        },
        checkStatus: async () => { const response = await api.getStatus(); if (response && response.isLoggedIn) { auth.onLoginSuccess(response.user); } else { ui.showScreen('auth'); } }
    };

    // === Game Logic Module: Uses the simplified API ===
    const game = {
        start: async (forceNew = false, replayGameId = null) => {
            const size = parseInt(DOMElements.boardSizeSelect.value, 10);
            const settings = { isDailyChallenge: state.isDaily, gameMode: state.gameMode, imageUrl: state.imageUrl, size: size, difficulty: parseInt(DOMElements.difficultySelect.value, 10), forceNew: forceNew, replayGameId: replayGameId };
            const gameState = await api.performAction('start', settings);
            if (gameState && gameState.active_session_found && !replayGameId) {
                if (confirm('У вас есть незаконченная игра. Хотите продолжить?')) {
                    ui.showScreen('game');
                    ui.render(gameState);
                    timer.start(gameState.startTime, gameState.boardSize);
                } else {
                    game.start(true, null);
                }
                return;
            }
            if (gameState && gameState.sessionId) {
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
        loadImages: async () => {
            DOMElements.defaultImagePreviews.innerHTML = '';
            DOMElements.userImagePreviews.innerHTML = '';

            const defaultImages = await api.performAction('get_default_images');
            if (defaultImages && defaultImages.length > 0) {
                defaultImages.forEach(imgData => {
                    const img = ui.createPreviewImage(`/api/image/${imgData.id}`, imgData.name);
                    DOMElements.defaultImagePreviews.appendChild(img);
                });
            }

            const userImages = await api.performAction('get_user_images');

            if (userImages && userImages.length > 0) {
                userImages.forEach(imgData => {
                    const altText = `User image ${imgData.id}`;
                    const imgContainer = ui.createUserPreviewImage(imgData.id, altText);
                    DOMElements.userImagePreviews.appendChild(imgContainer);
                });
            } else {
                DOMElements.userImagePreviews.innerHTML = '<p class="no-images-msg">Вы еще не загружали картинок.</p>';
            }

            const imageLimit = 7;
            if (userImages && userImages.length >= imageLimit) {
                DOMElements.uploadLabel.classList.add('hidden');
                DOMElements.customImageName.textContent = `Достигнут лимит в ${imageLimit} картинок.`;
            } else {
                DOMElements.uploadLabel.classList.remove('hidden');
                if (DOMElements.customImageName.textContent.startsWith('Достигнут')) {
                    DOMElements.customImageName.textContent = '';
                }
            }
        },
        createPreviewImage: (path, alt) => {
            const img = document.createElement('img');
            img.src = path;
            img.alt = alt;
            img.className = 'preview-img';
            img.dataset.src = path;
            img.addEventListener('click', ui.handlePreviewClick);
            return img;
        },
        createUserPreviewImage: (id, alt) => {
            const container = document.createElement('div');
            container.className = 'preview-container';

            const img = ui.createPreviewImage(`/api/image/${id}`, alt);
            container.appendChild(img);

            const deleteBtn = document.createElement('button');
            deleteBtn.className = 'delete-btn';
            deleteBtn.innerHTML = '<i class="fas fa-times"></i>';
            deleteBtn.dataset.imageId = id;

            container.appendChild(deleteBtn);
            return container;
        },
        handlePreviewClick: (event) => {
            document.querySelectorAll('.preview-img').forEach(i => i.classList.remove('selected'));
            event.target.classList.add('selected');
            state.imageUrl = event.target.dataset.src;
            DOMElements.customImageName.textContent = '';
            DOMElements.imageUpload.value = '';
        },
        handleImageUpload: async (event) => {
            const file = event.target.files[0];
            if (!file) return;

            const MAX_FILE_SIZE_MB = 5;
            const MAX_FILE_SIZE_BYTES = MAX_FILE_SIZE_MB * 1024 * 1024;

            if (file.size > MAX_FILE_SIZE_BYTES) {
                DOMElements.customImageName.textContent = `Ошибка: Файл слишком большой (макс. ${MAX_FILE_SIZE_MB} МБ).`;
                event.target.value = '';
                return;
            }

            const formData = new FormData();
            formData.append('image', file);
            DOMElements.customImageName.textContent = 'Загрузка...';
            
            const res = await api.uploadImage(formData);
            
            if (res && res.success) {
                if (res.status === 'uploaded') {
                    DOMElements.customImageName.textContent = `Загружено: ${file.name}`;
                    ui.loadImages();
                } else if (res.status === 'duplicate') {
                    DOMElements.customImageName.textContent = 'Такая картинка уже есть.';
                }
            } else {
                const errorMessage = res && res.error ? res.error : 'Ошибка загрузки.';
                DOMElements.customImageName.textContent = errorMessage;
            }

            event.target.value = '';
        },
        showScreen: (screenName) => {
            document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
            const screen = document.getElementById(`${screenName}-screen`); if(screen) screen.classList.add('active');
            if (state.currentUser) { DOMElements.navButtons.forEach(btn => { btn.classList.toggle('active', btn.dataset.screen === screenName); }); }
            if (screenName === 'leaderboard') { ui.renderLeaderboards(); }
            if (screenName === 'history') { ui.renderGameHistory(); }
        },
        updateLoginState: () => { const isLoggedIn = !!state.currentUser; DOMElements.userStatus.classList.toggle('hidden', !isLoggedIn); DOMElements.navMenu.classList.toggle('hidden', !isLoggedIn); if (isLoggedIn) { DOMElements.welcomeMessage.textContent = `Добро пожаловать, ${state.currentUser.name}!`; } },
        render: (gameState) => {
            const { boardSize, boardState, moves, status, imageUrl, gameMode, stars } = gameState;
            state.gameMode = gameMode;
            state.imageUrl = imageUrl;
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
                        if (gameMode === 'IMAGE' && imageUrl) {
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
                rows.forEach(row => { 
                    const tr = document.createElement('tr'); 
                    tr.innerHTML = columns.map(col => {
                        let content = row[col] !== undefined ? row[col] : '';
                        if (col === 'total_stars') { content = `<span class="star-count">${content}</span> <i class="fas fa-star gold-star"></i>`; }
                        return `<td>${content}</td>`;
                    }).join(''); 
                    tbody.appendChild(tr); 
                });
                table.appendChild(thead); table.appendChild(tbody); container.appendChild(table);
                return container;
            };
            DOMElements.leaderboardTables.appendChild(createTable('Топ игроков по звездам', ['Игрок', 'Всего звёзд'], data.leaderboard, ['user', 'total_stars']));
        },
        renderGameHistory: async () => {
            const historyData = await api.performAction('get_game_history');
            const container = DOMElements.historyTableContainer;
            container.innerHTML = ''; 

            if (!historyData || historyData.length === 0) {
                container.innerHTML = '<p>Вы еще не сыграли ни одной игры.</p>';
                return;
            }

            const table = document.createElement('table');
            table.className = 'history-table';
            table.innerHTML = `<thead><tr><th>Дата</th><th>Размер</th><th>Ходы</th><th>Время</th><th>Статус</th><th></th></tr></thead><tbody></tbody>`;
            const tbody = table.querySelector('tbody');

            historyData.forEach(game => {
                const minutes = String(Math.floor(game.time / 60)).padStart(2, '0');
                const seconds = String(game.time % 60).padStart(2, '0');
                const timeStr = `${minutes}:${seconds}`;

                const statusText = game.status === 'SOLVED' 
                    ? (game.stars > 0 ? `<span class="status-solved">${'★'.repeat(game.stars)}</span>` : 'Решено')
                    : '<span class="status-abandoned">Сдался</span>';

                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${game.date}</td>
                    <td>${game.size}x${game.size}</td>
                    <td>${game.moves}</td>
                    <td>${timeStr}</td>
                    <td>${statusText}</td>
                    <td><button class="btn btn-secondary replay-btn" data-game-id="${game.gameId}">Переиграть</button></td>
                `;
                tbody.appendChild(row);
            });
            container.appendChild(table);
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
        DOMElements.logoutBtn.addEventListener('click', auth.handleLogout);
        DOMElements.showRegisterLink.addEventListener('click', (e) => { e.preventDefault(); DOMElements.loginView.classList.add('hidden'); DOMElements.registerView.classList.remove('hidden'); DOMElements.authError.textContent = ''; });
        DOMElements.showLoginLink.addEventListener('click', (e) => { e.preventDefault(); DOMElements.loginView.classList.remove('hidden'); DOMElements.registerView.classList.add('hidden'); DOMElements.authError.textContent = ''; });
        DOMElements.navButtons.forEach(btn => btn.addEventListener('click', () => ui.showScreen(btn.dataset.screen)));
        DOMElements.dailyCheck.addEventListener('change', (e) => { state.isDaily = e.target.checked; DOMElements.regularSettings.classList.toggle('hidden', state.isDaily); });
        DOMElements.modeRadios.forEach(radio => radio.addEventListener('change', (e) => {
            state.gameMode = e.target.value;
            DOMElements.imageSelection.classList.toggle('hidden', state.gameMode !== 'IMAGE');
            // --- ИЗМЕНЕНО 2: Проверка теперь на 'INTS' ---
            if (state.gameMode === 'INTS') {
                state.imageUrl = null;
                document.querySelectorAll('.preview-img.selected').forEach(img => img.classList.remove('selected'));
            }
        }));
        DOMElements.imageUpload.addEventListener('change', ui.handleImageUpload);
        DOMElements.startBtn.addEventListener('click', () => game.start(false, null));
        DOMElements.gameBoard.addEventListener('click', (e) => { const tile = e.target.closest('.tile'); if (tile && tile.dataset.value) game.move(parseInt(tile.dataset.value, 10)); });
        DOMElements.hintBtn.addEventListener('click', game.hint);
        DOMElements.undoBtn.addEventListener('click', game.undo);
        DOMElements.redoBtn.addEventListener('click', game.redo);
        DOMElements.abandonBtn.addEventListener('click', game.abandon);
        DOMElements.playAgainBtn.addEventListener('click', game.playAgain);
        DOMElements.applyFiltersBtn.addEventListener('click', ui.renderLeaderboards);
        DOMElements.historyTableContainer.addEventListener('click', (event) => {
            if (event.target && event.target.classList.contains('replay-btn')) {
                const gameId = event.target.dataset.gameId;
                if (gameId) {
                    game.start(true, parseInt(gameId, 10));
                }
            }
        });
        document.addEventListener('keydown', (e) => {
            if(DOMElements.gameScreen.classList.contains('active')) {
                if(e.key.toLowerCase() === 'h') game.hint();
                if(e.key.toLowerCase() === 'u' && !e.shiftKey) { e.preventDefault(); game.undo(); }
                if(e.key.toLowerCase() === 'u' && e.shiftKey) { e.preventDefault(); game.redo(); }
            }
        });
        DOMElements.userImagePreviews.addEventListener('click', async (event) => {
            const deleteButton = event.target.closest('.delete-btn');
            if (deleteButton) {
                const imageId = deleteButton.dataset.imageId;
                if (confirm('Вы уверены, что хотите удалить эту картинку?')) {
                    const response = await api.performAction('delete_image', { imageId });
                    if (response && response.success) {
                        ui.loadImages();
                    } else {
                        alert('Не удалось удалить картинку.');
                    }
                }
            }
        });
        auth.checkStatus();
    }
    init();
});