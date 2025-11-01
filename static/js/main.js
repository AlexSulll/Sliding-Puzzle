document.addEventListener('DOMContentLoaded', () => {
    const state = {
        currentUser: null,
        timerInterval: null,
        totalSeconds: 0,
        activeGameSessionId: null,
        gameMode: 'INTS',
        imageUrl: null,
        imageId: null,
        isUploadingForGameStart: false,
        isDaily: false,
        currentBoardState: [],
        boardSize: 0,
        isLoading: false,
        currentReplayId: null,
    };

    const DOMElements = {
        authScreen: document.getElementById('auth-screen'),
        settingsScreen: document.getElementById('settings-screen'),
        dailyChallengeScreen: document.getElementById('daily-challenge-screen'),
        dailyLeaderboardContainer: document.getElementById('daily-leaderboard-container'),
        startDailyChallengeBtn: document.getElementById('start-daily-challenge-btn'),
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
        historyTableContainer: document.getElementById('history-table-container'),
        userStatsPanel: document.getElementById('user-stats-panel'),
        statsUsername: document.getElementById('stats-username'),
        restartBtn: document.getElementById('restart-btn'),
        progressCounter: document.getElementById('progress-counter'),
        loadingOverlay: document.getElementById('loading-overlay'),
        loadingText: document.getElementById('loading-text'),
        historyFilterSize: document.getElementById('history-filter-size'),
        historyFilterDifficulty: document.getElementById('history-filter-difficulty'),
        historyFilterUnfinished: document.getElementById('history-filter-unfinished'),
        applyHistoryFiltersBtn: document.getElementById('apply-history-filters-btn'),
        backToGameBtn: document.getElementById('back-to-game-btn'),
    };

    const api = {
        async call(endpoint, options = {}, loadingMessage) {
            if (state.isLoading) {
                console.warn("Предыдущий запрос еще выполняется.");
                return;
            }

            state.isLoading = true;
            let loaderTimeout = null;

            if (loadingMessage) {
                loaderTimeout = setTimeout(() => {
                    ui.showLoader(loadingMessage);
                }, 500);
            }

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
            } finally {
                clearTimeout(loaderTimeout);
                state.isLoading = false;
                ui.hideLoader();
            }
        },
        performAction: (action, params = {}, loadingMessage) => api.call('/api/action', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, params }), }, loadingMessage),
        register: (username, passwordHash) => api.call('/api/auth/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, passwordHash }) }),
        login: (username, passwordHash) => api.call('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, passwordHash }) }),
        logout: () => api.call('/api/auth/logout', { method: 'POST' }),
        getStatus: () => api.call('/api/auth/status'),
        uploadImage: (formData) => api.call('/api/upload-image', { method: 'POST', body: formData }),
    };

    const auth = {
        hashPassword: (password) => CryptoJS.SHA256(password).toString(CryptoJS.enc.Hex).toUpperCase(),
        validateUsername: (username) => { if (username.length === 0) { return { isValid: false, message: 'Имя пользователя не может быть пустым' }; } if (username.length > 50 || username.length < 3) { return { isValid: false, message: 'Имя пользователя должно содержать от 3 до 50 символов' }; } const validUsernameRegex = /^[a-zA-Z0-9_-]+$/; if (!validUsernameRegex.test(username)) { return {  isValid: false, message: 'Имя пользователя может содержать только латинские буквы, цифры, знаки "-" и "_"'  }; } return { isValid: true, message: '' }; },
        showError: (message) => { DOMElements.authError.textContent = message; DOMElements.authError.classList.add('show');  document.querySelectorAll('#auth-screen input').forEach(input => { input.classList.add('error');}); setTimeout(() => { auth.hideError(); }, 5000); },
        hideError: () => { DOMElements.authError.classList.remove('show'); DOMElements.authError.textContent = ''; document.querySelectorAll('#auth-screen input').forEach(input => { input.classList.remove('error'); }); },
        clearForms: () => { document.querySelectorAll('#auth-screen form').forEach(form => form.reset()); auth.hideError(); },
        handleLogin: async (event) => { event.preventDefault(); auth.hideError(); const username = document.getElementById('login-username').value.trim(); const password = document.getElementById('login-password').value; if (!username || !password) { auth.showError('Пожалуйста, заполните все поля'); return; } const loginBtn = document.getElementById('login-btn'); const originalText = loginBtn.innerHTML; loginBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Вход...'; loginBtn.disabled = true; try { const response = await api.login(username, auth.hashPassword(password)); if (response && response.success) { auth.onLoginSuccess(response.user); } else { auth.showError(response?.message || 'Неверное имя пользователя или пароль'); } } catch (error) { auth.showError('Ошибка соединения. Попробуйте позже.'); } finally { loginBtn.innerHTML = originalText; loginBtn.disabled = false; } },
        handleRegister: async (event) => { event.preventDefault(); auth.hideError(); const username = document.getElementById('register-username').value.trim(); const password = document.getElementById('register-password').value; const usernameValidation = auth.validateUsername(username); if (!usernameValidation.isValid) { auth.showError(usernameValidation.message); return; } if (!password) { auth.showError('Пожалуйста, введите пароль'); return; } if (password.length < 8) { auth.showError('Пароль должен содержать минимум 8 символов'); return; } const registerBtn = document.getElementById('register-btn'); const originalText = registerBtn.innerHTML; registerBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Регистрация...'; registerBtn.disabled = true; try { const response = await api.register(username, auth.hashPassword(password)); if (response && response.success) { auth.onLoginSuccess(response.user); } else { auth.showError(response?.message || 'Ошибка регистрации. Возможно, имя пользователя уже занято.'); } } catch (error) { auth.showError('Ошибка соединения. Попробуйте позже.'); } finally { registerBtn.innerHTML = originalText; registerBtn.disabled = false; } },
        handleLogout: async () => { await api.logout(); state.currentUser = null; ui.updateLoginState(); if (DOMElements.userStatsPanel) DOMElements.userStatsPanel.classList.add('hidden'); DOMElements.loginView.classList.remove('hidden'); DOMElements.registerView.classList.add('hidden'); ui.showScreen('auth'); auth.clearForms(); auth.hideError(); },
        onLoginSuccess: async (userData, activeGameId = null) => { state.currentUser = userData; state.activeGameSessionId = activeGameId; ui.loadImages(); await ui.renderUserStats(); await ui.updateLoginState(); ui.showScreen('settings'); auth.hideError(); auth.clearForms(); },
        checkStatus: async () => { const response = await api.getStatus(); if (response && response.isLoggedIn) { auth.onLoginSuccess(response.user, response.activeGameSessionId); } else { ui.showScreen('auth'); } }
    };

    const game = {
        start: async (forceNew = false, replayGameId = null) => {
            if (replayGameId) {
                state.currentReplayId = replayGameId;
            }

            const size = state.isDaily ? 4 : parseInt(DOMElements.boardSizeSelect.value, 10);
            const settings = {
                isDailyChallenge: state.isDaily,
                gameMode: state.isDaily ? 'INTS' : state.gameMode,
                imageId: state.isDaily ? null : state.imageId,
                size: size,
                difficulty: state.isDaily ? 60 : parseInt(DOMElements.difficultySelect.value, 10),
                forceNew: forceNew,
                replayGameId: state.currentReplayId
            };
            
            const gameState = await api.performAction('start', settings, 'Генерация игры...');

            if (gameState && gameState.imageMissing) {
                const choiceStandard = confirm("Картинка для этой игры была удалена. Хотите выбрать стандартную картинку?");

                if (choiceStandard) {
                    const randomImageId = Math.floor(Math.random() * 3) + 1;
                    state.imageId = randomImageId;
                    state.gameMode = 'IMAGE';
                    game.start(true, state.currentReplayId);
                } else {
                    const choiceUpload = confirm("Хотите загрузить новую картинку?");
                    if (choiceUpload) {
                        state.isUploadingForGameStart = true;
                        DOMElements.uploadLabel.click();
                    } else {
                        const choiceNumbers = confirm("Тогда продолжить с числами?");
                        if (choiceNumbers) {
                            state.imageId = null;
                            state.gameMode = 'INTS';
                            game.start(true, state.currentReplayId);
                        } else {
                            state.currentReplayId = null;
                            ui.showScreen('settings');
                        }
                    }
                }
                return;
            }

            if (gameState && gameState.active_session_found && !replayGameId) {
                if (confirm('У вас есть незаконченная игра. Хотите продолжить игру?')) {
                    state.activeGameSessionId = gameState.sessionId;
                    ui.showScreen('game');
                    ui.render(gameState);
                    timer.start(gameState.timeRemaining);
                } else {
                    game.start(true, null);
                }
                return;
            }

            if (gameState && gameState.sessionId) {
                state.activeGameSessionId = gameState.sessionId;
                state.currentReplayId = null;
                ui.showScreen('game');
                ui.render(gameState);
                timer.start(gameState.timeRemaining);
            }
        },
        move: async (tileValue) => { 
            const gameState = await api.performAction('move', { tile: tileValue }, 'Обработка хода...'); 
            if (gameState) ui.render(gameState); 
        },
        undo: async () => { 
            const gameState = await api.performAction('undo', {}, 'Отмена хода...');
            if (gameState) ui.render(gameState); 
        },
        redo: async () => { 
            const gameState = await api.performAction('redo', {}, 'Возврат хода...');
            if (gameState) ui.render(gameState); 
        },
        abandon: async () => { await api.performAction('abandon'); timer.stop(); state.activeGameSessionId = null; ui.resetSettingsToDefault(); ui.showScreen('settings'); },
        playAgain: () => { timer.stop(); state.activeGameSessionId = null; ui.resetSettingsToDefault(); ui.showScreen('settings'); },
        hint: async () => { const data = await api.performAction('hint'); if(data && data.hint) { ui.highlightHint(data.hint); } },
        timeout: async () => { await api.performAction('timeout'); timer.stop(); state.activeGameSessionId = null; ui.showScreen('settings'); },
        restart: async () => { 
            const gameState = await api.performAction('restart', {}, 'Перезапуск игры...');
            if (gameState) { 
                timer.stop(); 
                ui.render(gameState); 
                timer.start(gameState.timeRemaining); 
            } 
        },
        resume: async (gameId) => {
            const gameState = await api.performAction('resume_game', { gameId: gameId }, 'Загрузка игры...');
            
            if (gameState && gameState.sessionId) {
                ui.showScreen('game');
                ui.render(gameState);
                timer.start(gameState.timeRemaining);
            } else {
                state.activeGameSessionId = null;
                ui.showScreen('settings');
            }
        },
    };
    
    const ui = {
        formatTime: (totalSeconds) => {
            if (!totalSeconds || totalSeconds === 0) return '--:--';
            const minutes = String(Math.floor(totalSeconds / 60)).padStart(2, '0');
            const seconds = String(totalSeconds % 60).padStart(2, '0');
            return `${minutes}:${seconds}`;
        },
        
        formatPlayerStatus: (lastSeenRaw, currentDbTimeRaw) => {
            if (!lastSeenRaw || !currentDbTimeRaw) {
                return `<span class="status-indicator offline"></span><span class="last-seen-text">нет данных</span>`;
            }

            const lastSeenDate = new Date(lastSeenRaw);
            const now = new Date(currentDbTimeRaw);

            const diffMinutes = (now.getTime() - lastSeenDate.getTime()) / (1000 * 60);

            if (diffMinutes < 5) {
                return `<span class="status-indicator online"></span><span class="last-seen-text">В сети</span>`;
            } 
            
            const day = String(lastSeenDate.getDate()).padStart(2, '0');
            const month = String(lastSeenDate.getMonth() + 1).padStart(2, '0');
            const hours = String(lastSeenDate.getHours()).padStart(2, '0');
            const minutes = String(lastSeenDate.getMinutes()).padStart(2, '0');
            const formattedDate = `${day}.${month} ${hours}:${minutes}`;
            
            return `<span class="status-indicator offline"></span><span class="last-seen-text">был(а) ${formattedDate}</span>`;
        },

        showLoader: (message = 'Загрузка...') => {
            DOMElements.loadingText.textContent = message;
            DOMElements.loadingOverlay.classList.remove('hidden');
        },

        hideLoader: () => {
            DOMElements.loadingOverlay.classList.add('hidden');
        },

        renderUserStats: async () => {
            return ui.refreshUserData();
        },

        loadImages: async () => {
            DOMElements.defaultImagePreviews.innerHTML = '';
            DOMElements.userImagePreviews.innerHTML = '';

            const defaultImages = await api.performAction('get_default_images');
            if (defaultImages && defaultImages.length > 0) {
                DOMElements.defaultImagePreviews.innerHTML = '';
                defaultImages.forEach(imgData => {
                    const path = `/api/image/${imgData.id}`;
                    const img = ui.createPreviewImage(path, imgData.name, imgData.id);
                    DOMElements.defaultImagePreviews.appendChild(img);
                });
            }

            const userImages = await api.performAction('get_user_images');
            if (userImages && userImages.length > 0) {
                DOMElements.userImagePreviews.innerHTML = '';
                userImages.forEach(imgData => {
                    const path = `/static${imgData.path}`;
                    const altText = `User image ${imgData.id}`;
                    const imgContainer = ui.createUserPreviewImage(imgData.id, path, altText);
                    DOMElements.userImagePreviews.appendChild(imgContainer);
                });
            } else {
                DOMElements.userImagePreviews.innerHTML = '<p class="no-images-msg">Вы еще не загружали картинок.</p>';
            }
        },
        createPreviewImage: (path, alt, id = null) => {
            const img = document.createElement('img');
            img.src = path;
            img.alt = alt;
            img.className = 'preview-img';
            img.dataset.src = path;
            if (id) {
                img.dataset.imageId = id;
            }
            img.addEventListener('click', ui.handlePreviewClick);
            return img;
        },
        createUserPreviewImage: (id, path, alt) => {
            const container = document.createElement('div');
            container.className = 'preview-container';

            const img = ui.createPreviewImage(path, alt, id);
            container.appendChild(img);

            const deleteBtn = document.createElement('button');
            deleteBtn.className = 'delete-btn';
            deleteBtn.innerHTML = '<i class="fas fa-times"></i>';
            deleteBtn.dataset.imageId = id;

            container.appendChild(deleteBtn);
            return container;
        },
        handlePreviewClick: (event) => {
            state.gameMode = 'IMAGE';
            document.getElementById('mode-image').checked = true;
            DOMElements.imageSelection.classList.remove('hidden');
            document.querySelectorAll('.preview-img').forEach(i => i.classList.remove('selected'));
            event.target.classList.add('selected');
            state.imageUrl = event.target.dataset.src;
            state.imageId = event.target.dataset.imageId;
            DOMElements.customImageName.textContent = '';
            DOMElements.imageUpload.value = '';
        },
        handleImageUpload: async (event) => {
            const file = event.target.files[0];
            if (!file) return;

            const allowedTypes = ['image/jpeg', 'image/png'];

            if (!allowedTypes.includes(file.type)) {
                DOMElements.customImageName.textContent = 'Ошибка: Разрешены только JPG и PNG.';
                event.target.value = '';
                return;
            }

            const formData = new FormData();
            formData.append('image', file);
            
            const res = await api.uploadImage(formData);
            
        if (res && res.success) {
            if (res.status === 'uploaded') {
                if (state.isUploadingForGameStart) {
                    state.isUploadingForGameStart = false;
                    state.imageId = res.newImage.id;
                    state.gameMode = 'IMAGE';
                    await ui.loadImages();
                    game.start(true, state.currentReplayId);
                } else {
                    await ui.loadImages();
                }
            } else if (res.status === 'duplicate') {
                DOMElements.customImageName.textContent = 'Такая картинка уже есть.';
                if(state.isUploadingForGameStart) state.isUploadingForGameStart = false;
            }
        } else {
            const errorMessage = res && res.error ? res.error : 'Ошибка загрузки.';
            DOMElements.customImageName.textContent = errorMessage;
        }

            event.target.value = '';
        },

        showScreen: (screenName) => {
            document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
            const screen = document.getElementById(`${screenName}-screen`); 
            if(screen) screen.classList.add('active');
            
            if (state.currentUser) { 
                DOMElements.navButtons.forEach(btn => { 
                    btn.classList.toggle('active', btn.dataset.screen === screenName); 
                }); 
            }
            
            if (state.activeGameSessionId && screenName !== 'game') {
                DOMElements.backToGameBtn.classList.remove('hidden');
            } else {
                DOMElements.backToGameBtn.classList.add('hidden');
            }

            if (screenName === 'leaderboard') { 
                ui.renderLeaderboards(); 
            }
            if (screenName === 'history') { 
                ui.renderGameHistory(); 
            }
            if (screenName === 'settings') { 
                DOMElements.dailyCheck.checked = false;
                state.isDaily = false;
                DOMElements.regularSettings.classList.remove('hidden');
                
                setTimeout(() => {
                    ui.refreshUserData();
                }, 100);
            }
        },

        updateLoginState: async () => { 
            const isLoggedIn = !!state.currentUser; 
            DOMElements.userStatus.classList.toggle('hidden', !isLoggedIn); 
            DOMElements.navMenu.classList.toggle('hidden', !isLoggedIn); 
            
            if (isLoggedIn) { 
                await ui.refreshUserData();
            } 
        },

        render: (gameState) => {
            const { boardSize, boardState, moves, status, imageUrl, gameMode, stars, progress } = gameState;
            state.gameMode = gameMode;
            state.imageUrl = imageUrl;
            state.currentBoardState = boardState;
            state.boardSize = boardSize;
            DOMElements.movesCounter.textContent = moves;
            
            if (status === 'SOLVED') {
                timer.stop();
                state.activeGameSessionId = null;
                DOMElements.winMoves.textContent = moves;
                const timeElapsed = gameState.duration;
                DOMElements.winTime.textContent = ui.formatTime(timeElapsed);
                DOMElements.winStars.innerHTML = (stars > 0) ? '★'.repeat(stars) + '☆'.repeat(3 - stars) : 'Решено';
                DOMElements.activeGameView.classList.add('hidden');
                DOMElements.winOverlay.classList.remove('hidden');
                
                ui.updateLoginState();
            } else {
                if (DOMElements.progressCounter && progress !== undefined) {
                    DOMElements.progressCounter.textContent = `${progress}%`;
                }
                DOMElements.activeGameView.classList.remove('hidden');
                DOMElements.winOverlay.classList.add('hidden');
                document.documentElement.style.setProperty('--board-size', boardSize);
                DOMElements.gameBoard.innerHTML = '';
                
                boardState.forEach(value => {
                    const tile = document.createElement('div'); 
                    tile.classList.add('tile');
                    if (value === 0) { 
                        tile.classList.add('empty'); 
                    } else {
                        tile.dataset.value = value;
                        if (gameMode === 'IMAGE' && imageUrl) {
                            let finalImageUrl = imageUrl;
                            if (imageUrl.startsWith('/uploads/')) {
                                finalImageUrl = `/static${imageUrl}`;
                            }
                            const col = (value - 1) % boardSize;
                            const row = Math.floor((value - 1) / boardSize);
                            tile.style.backgroundImage = `url(${finalImageUrl})`;
                            tile.style.backgroundPosition = `${(col * 100) / (boardSize - 1)}% ${(row * 100) / (boardSize - 1)}%`;
                        } else {
                            tile.textContent = value;
                        }
                    }
                    DOMElements.gameBoard.appendChild(tile);
                });
            }
        },

        renderLeaderboards: async () => {
            const size = DOMElements.filterSize.value;
            const difficulty = DOMElements.filterDifficulty.value;
            const data = await api.performAction('get_leaderboards', { size, difficulty });
            const container = DOMElements.leaderboardTables;
            container.innerHTML = '';
            
            const currentDbTimeRaw = data.current_time_raw; 

            if (!data?.leaderboard) {
                container.innerHTML = '<p><i>Пока нет данных для выбранных фильтров</i></p>';
                return;
            }

            const table = document.createElement('table');
            table.className = 'leaderboard-table';
            table.innerHTML = `
                <thead>
                    <tr>
                        <th>Место</th>
                        <th>Игрок</th>
                        <th>Статус</th>
                        <th>Звёзды</th>
                        <th>Решено</th>
                        <th>Не завершено</th>
                    </tr>
                </thead>
                <tbody></tbody>
            `;
            const tbody = table.querySelector('tbody');

            const currentUser = state.currentUser;
            const currentUserData = currentUser ? 
                data.leaderboard.find((player, index) => {
                    if (player.user.toLowerCase() === currentUser.name.toLowerCase()) {
                        player.position = index;
                        return true;
                    }
                    return false;
                }) : null;

            const shouldShowFull = !currentUserData || currentUserData.position < 5;
            
            if (shouldShowFull) {
                renderFullLeaderboard();
            } else {
                renderCompactLeaderboard();
            }

            container.appendChild(table);

            function renderFullLeaderboard() {
                tbody.innerHTML = '';
                data.leaderboard.forEach((player, index) => {
                    tbody.appendChild(createPlayerRow(player, index));
                });
            }

            function renderCompactLeaderboard() {
                tbody.innerHTML = ''; 
                
                data.leaderboard.slice(0, 3).forEach((player, index) => {
                    tbody.appendChild(createPlayerRow(player, index));
                });

                const separatorRow = document.createElement('tr');
                separatorRow.className = 'separator-row clickable-separator';
                separatorRow.innerHTML = `<td colspan="6"><div class="table-separator">... показать всех ...</div></td>`;
                separatorRow.addEventListener('click', renderFullLeaderboard);
                tbody.appendChild(separatorRow);

                const userPosition = currentUserData.position;
                data.leaderboard.slice(userPosition).forEach((player, index) => {
                    const position = userPosition + index;
                    const row = createPlayerRow(player, position);
                    if (position === userPosition) row.classList.add('current-user-row');
                    tbody.appendChild(row);
                });
            }

            function createPlayerRow(player, position) {
                const row = document.createElement('tr');
                const maxLength = 17;
                const truncatedUsername = player.user.length > maxLength ? 
                    player.user.slice(0, maxLength) + '...' : player.user;

                const place = getPlaceIcon(position);
                const statusHtml = ui.formatPlayerStatus(player.last_seen_raw, currentDbTimeRaw);
                const isCurrentUser = currentUserData?.position === position;

                row.innerHTML = `
                    <td>${place}</td>
                    <td>${truncatedUsername}${isCurrentUser ? ' <span class="you-badge">(Вы)</span>' : ''}</td>
                    <td class="player-status">${statusHtml}</td>
                    <td><span class="star-count">${player.total_stars}</span> <i class="fas fa-star gold-star"></i></td>
                    <td>${player.solved_games}</td>
                    <td>${player.unfinished_games}</td>
                `;
                
                if (isCurrentUser) row.classList.add('current-user-row');
                return row;
            }

            function getPlaceIcon(position) {
                if (position < 3) {
                    return ['<span class="trophy-icon">🏆</span>',
                        '<span class="trophy-icon"><i class="fas fa-medal" style="color: silver;"></i></span>',
                        '<span class="trophy-icon"><i class="fas fa-medal" style="color: #cd7f32;"></i></span>'][position];
                }
                return `#${position + 1}`;
            }
        },

        refreshUserData: async () => {
            if (!state.currentUser) return;
            
            try {
                const stats = await api.performAction('get_user_stats');
                if (stats) {
                    const maxLength = 32;
                    const truncatedName = state.currentUser.name.length > maxLength ? state.currentUser.name.slice(0, maxLength) + '...' : state.currentUser.name;
                    state.currentUser.total_stars = stats.total_stars;
                    DOMElements.welcomeMessage.innerHTML = `Добро пожаловать, ${truncatedName} <span class="user-stars">${stats.total_stars} ★</span>`;
                }
            } catch (error) {
                console.error('Error refreshing user data:', error);
            }
        },

        renderGameHistory: async () => {
            const size = DOMElements.historyFilterSize.value;
            const difficulty = parseInt(DOMElements.historyFilterDifficulty.value, 10);
            const unfinished = DOMElements.historyFilterUnfinished.checked ? 'abandoned' : '0';
            
            const historyData = await api.performAction('get_game_history', {
                size: size,
                difficulty: difficulty,
                result: unfinished
            });
            
            const container = DOMElements.historyTableContainer;
            container.innerHTML = ''; 

            if (!historyData || historyData.length === 0) {
                container.innerHTML = '<p><i>Нет игр, соответствующих выбранным фильтрам</i></p>';
                return;
            }

            const table = document.createElement('table');
            table.className = 'history-table';
            table.innerHTML = `<thead><tr><th>Дата</th><th>Размер</th><th>Ходы</th><th>Время</th><th>Статус</th><th></th></tr></thead><tbody></tbody>`;
            const tbody = table.querySelector('tbody');

            historyData.forEach(game => {
                let timeStr = ui.formatTime(game.time);
                let statusText = '';
                let moves = game.moves;
                const shouldPulse = game.stars != 3;

                if (game.status === 'SOLVED') {
                    statusText = game.stars > 0 ? `<span class="status-solved">${'★'.repeat(game.stars)}</span>` : 'Решено';
                } else if (game.status === 'ABANDONED') {
                    statusText = '<span class="status-abandoned">Сдался</span>';
                } else if (game.status === 'TIMEOUT') {
                    statusText = '<span class="status-timeout">Время вышло</span>';
                    if (game.size === 3) {
                        timeStr = '08:00'
                    } else if (game.size === 4) {
                        timeStr = '10:00'
                    } else if (game.size === 5) {
                        timeStr = '13:00'
                    } else {
                        timeStr = '15:00'
                    }
                }

                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${game.date}</td>
                    <td>${game.size}x${game.size}</td>
                    <td>${moves}</td>
                    <td>${timeStr}</td>
                    <td>${statusText}</td>
                    <td><button class="replay-btn ${shouldPulse ? 'pulsing' : ''}" data-game-id="${game.gameId}"><i class="fas fa-play"></i> Переиграть</button></td>
                `;
                tbody.appendChild(row);
            });
            container.appendChild(table);
        },

        
        renderDailyLeaderboard: async () => {
            const data = await api.performAction('get_daily_leaderboard');
            const container = DOMElements.dailyLeaderboardContainer;

            container.innerHTML = ''; 
            
            const currentDbTimeRaw = data.current_time_raw;

            if (!data || !data.leaderboard || data.leaderboard.length === 0) {
                container.innerHTML = '<p><i>Сегодня еще никто не прошел челлендж. Будьте первым!</i></p>';
                return;
            }

            const table = document.createElement('table');
            table.className = 'leaderboard-table';
            container.innerHTML = '';
            table.innerHTML = `
                <thead>
                    <tr>
                        <th>Место</th>
                        <th>Игрок</th>
                        <th>Статус</th>
                        <th>Ходы</th>
                        <th>Время</th>
                    </tr>
                </thead>
                <tbody></tbody>
            `;
            const tbody = table.querySelector('tbody');

            data.leaderboard.forEach((player, index) => {
                const row = document.createElement('tr');
                const place = ['🏆', '<i class="fas fa-medal" style="color: silver;"></i>', '<i class="fas fa-medal" style="color: #cd7f32;"></i>'][index] || `#${index + 1}`;
                
                const statusHtml = ui.formatPlayerStatus(player.last_seen_raw, currentDbTimeRaw);

                row.innerHTML = `
                    <td>${place}</td>
                    <td>${player.user}</td>
                    <td class="player-status">${statusHtml}</td>
                    <td><strong>${player.moves}</strong></td>
                    <td>${ui.formatTime(player.time)}</td>
                `;
                tbody.appendChild(row);
            });
            container.appendChild(table);
        },
        highlightHint: (tileValue) => { const tile = DOMElements.gameBoard.querySelector(`[data-value="${tileValue}"]`); if (tile) { tile.classList.add('hint'); setTimeout(() => tile.classList.remove('hint'), 1000); } },
        resetSettingsToDefault: () => {
            state.gameMode = 'INTS';
            state.imageId = null;
            state.imageUrl = null;
            document.getElementById('mode-numbers').checked = true;
            DOMElements.imageSelection.classList.add('hidden');
            document.querySelectorAll('.preview-img.selected').forEach(img => img.classList.remove('selected'));
        },
    };

    const timer = {
        start: (initialTimeRemaining) => {
            timer.stop();
            
            state.totalSeconds = initialTimeRemaining; 

            if (state.totalSeconds <= 0) {
                DOMElements.timerDisplay.textContent = '00:00';
                return;
            }

            DOMElements.timerDisplay.textContent = ui.formatTime(state.totalSeconds);

            state.timerInterval = setInterval(() => {

                state.totalSeconds--; 

                if (state.totalSeconds <= 0) {
                    DOMElements.timerDisplay.textContent = '00:00';
                    timer.stop();
                    alert('Время вышло!');
                    game.timeout();
                    return;
                }
                
                DOMElements.timerDisplay.textContent = ui.formatTime(state.totalSeconds);
            }, 1000);
        },
        stop: () => { 
            if (state.timerInterval) clearInterval(state.timerInterval); 
            state.timerInterval = null; 
            state.totalSeconds = 0;
        }
    };

    function init() {
        DOMElements.loginForm.addEventListener('submit', auth.handleLogin);
        DOMElements.registerForm.addEventListener('submit', auth.handleRegister);
        DOMElements.logoutBtn.addEventListener('click', auth.handleLogout);
        DOMElements.showRegisterLink.addEventListener('click', (e) => { e.preventDefault(); DOMElements.loginView.classList.add('hidden'); DOMElements.registerView.classList.remove('hidden'); DOMElements.authError.textContent = ''; });
        DOMElements.showLoginLink.addEventListener('click', (e) => { e.preventDefault(); DOMElements.loginView.classList.remove('hidden'); DOMElements.registerView.classList.add('hidden'); DOMElements.authError.textContent = ''; });
        DOMElements.navButtons.forEach(btn => btn.addEventListener('click', () => ui.showScreen(btn.dataset.screen)));
        DOMElements.applyHistoryFiltersBtn.addEventListener('click', ui.renderGameHistory);
        DOMElements.dailyCheck.addEventListener('change', (e) => {
            if (e.target.checked) {
                ui.showScreen('daily-challenge');
                ui.renderDailyLeaderboard();
            } else {
                ui.showScreen('settings');
            }
        });
        
        DOMElements.modeRadios.forEach(radio => radio.addEventListener('change', (e) => {
            state.gameMode = e.target.value;
            DOMElements.imageSelection.classList.toggle('hidden', state.gameMode !== 'IMAGE');
            if (state.gameMode === 'INTS') {
                state.imageUrl = null;
                state.imageId = null;
                document.querySelectorAll('.preview-img.selected').forEach(img => img.classList.remove('selected'));
            }
        }));
        DOMElements.imageUpload.addEventListener('change', ui.handleImageUpload);
        DOMElements.startBtn.addEventListener('click', () => {
            if (state.gameMode === 'IMAGE' && !state.imageId) {
                alert('Пожалуйста, выберите картинку для игры.');
                return;
            }
            game.start(false, null);
        });
        DOMElements.gameBoard.addEventListener('click', (e) => { const tile = e.target.closest('.tile'); if (tile && tile.dataset.value) game.move(parseInt(tile.dataset.value, 10)); });
        DOMElements.hintBtn.addEventListener('click', game.hint);
        DOMElements.undoBtn.addEventListener('click', game.undo);
        DOMElements.redoBtn.addEventListener('click', game.redo);
        DOMElements.abandonBtn.addEventListener('click', game.abandon);
        DOMElements.playAgainBtn.addEventListener('click', game.playAgain);
        DOMElements.applyFiltersBtn.addEventListener('click', ui.renderLeaderboards);
        DOMElements.restartBtn.addEventListener('click', game.restart);
        DOMElements.historyTableContainer.addEventListener('click', (event) => {
            if (event.target && event.target.classList.contains('replay-btn')) {
                const gameId = event.target.dataset.gameId;
                if (gameId) {
                    game.start(true, parseInt(gameId, 10));
                }
            }
        });
        document.addEventListener('keydown', (e) => {
            if (!DOMElements.gameScreen.classList.contains('active')) return;
            
            const code = e.code;
            const isShift = e.shiftKey;

            switch (code) {
                case 'KeyH':
                    e.preventDefault();
                    game.hint();
                    break;
                case 'KeyU':
                    e.preventDefault();
                    if (isShift) {
                        game.redo();
                    } else {
                        game.undo();
                    }
                    break;
                case 'KeyR':
                    e.preventDefault();
                    if (DOMElements.gameScreen.classList.contains('active')) {
                        game.restart();
                    } else {
                        game.playAgain();
                    }
                    break;
            }
            
            const emptyIndex = state.currentBoardState.indexOf(0);
            if (emptyIndex === -1) return;

            let targetIndex = -1;
            const size = state.boardSize;

            if (e.key === 'ArrowUp' && emptyIndex < size * (size - 1)) {
                targetIndex = emptyIndex + size;
            } else if (e.key === 'ArrowDown' && emptyIndex >= size) {
                targetIndex = emptyIndex - size;
            } else if (e.key === 'ArrowLeft' && (emptyIndex % size) < (size - 1)) {
                targetIndex = emptyIndex + 1;
            } else if (e.key === 'ArrowRight' && (emptyIndex % size) > 0) {
                targetIndex = emptyIndex - 1;
            }

            if (targetIndex !== -1) {
                e.preventDefault();
                const tileValue = state.currentBoardState[targetIndex];
                if (tileValue) {
                    game.move(tileValue);
                }
            }
        });

        const dailyLabel = document.querySelector('.daily-label');
        const dailyTextPrimary = document.querySelector('.daily-text-primary');
        const dailyTextSecondary = document.querySelector('.daily-text-secondary');
        const dailyIcon = document.querySelector('.daily-label i');

        if (dailyLabel) {
            dailyLabel.addEventListener('mouseenter', () => {
                dailyTextPrimary.style.transition = 'transform 0.3s ease';
                dailyTextSecondary.style.transition = 'transform 0.3s ease';
                if (dailyIcon) {
                    dailyIcon.style.transition = 'transform 0.3s ease, color 0.3s ease';
                }
            });

            dailyLabel.addEventListener('mouseleave', () => {
                dailyTextPrimary.style.transition = 'transform 0.3s ease';
                dailyTextSecondary.style.transition = 'transform 0.3s ease';
                if (dailyIcon) {
                    dailyIcon.style.transition = 'transform 0.3s ease, color 0.3s ease';
                }
            });
        }

        document.querySelectorAll('.size-btn').forEach(btn => {
            btn.addEventListener('click', function() {
                document.querySelectorAll('.size-btn').forEach(b => b.classList.remove('active'));
                this.classList.add('active');
                const size = this.dataset.size;
                DOMElements.boardSizeSelect.value = size;
                DOMElements.boardSizeSelect.dispatchEvent(new Event('change'));
            });
        });

        document.querySelectorAll('.difficulty-btn').forEach(btn => {
            btn.addEventListener('click', function() {
                document.querySelectorAll('.difficulty-btn').forEach(b => b.classList.remove('active'));
                this.classList.add('active');
                const difficulty = this.dataset.difficulty;
                DOMElements.difficultySelect.value = difficulty;
                DOMElements.difficultySelect.dispatchEvent(new Event('change'));
            });
        });

        const initialDifficulty = DOMElements.difficultySelect.value;
        document.querySelector(`.difficulty-btn[data-difficulty="${initialDifficulty}"]`).classList.add('active');

        const initialSize = DOMElements.boardSizeSelect.value;
        document.querySelector(`.size-btn[data-size="${initialSize}"]`).classList.add('active');

        DOMElements.userImagePreviews.addEventListener('click', async (event) => {
            const deleteButton = event.target.closest('.delete-btn');
            if (deleteButton) {
                DOMElements.customImageName.textContent = '';

                const imageId = deleteButton.dataset.imageId;
                if (confirm('Вы уверены, что хотите удалить эту картинку?')) {
                    const response = await api.performAction('delete_image', { imageId });
                    if (response && response.success) {
                        ui.loadImages();
                    } else {
                        const errorMessage = response && response.message ? response.message : 'Не удалось удалить картинку.';
                        DOMElements.customImageName.textContent = errorMessage;
                    }
                }
            }
        });
        DOMElements.startDailyChallengeBtn.addEventListener('click', () => {
            state.isDaily = true;
            DOMElements.regularSettings.classList.add('hidden');
            game.start(false, null);
        });

        DOMElements.backToGameBtn.addEventListener('click', (e) => {
            e.preventDefault();
            if (state.activeGameSessionId) {
                game.resume(state.activeGameSessionId);
            } else {
                ui.showScreen('game');
            }
        });

        auth.checkStatus();
    }
    init();
});