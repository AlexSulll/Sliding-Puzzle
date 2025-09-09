CREATE OR REPLACE PACKAGE GAME_MANAGER_PKG AS

    ----------------------------------------------------------------------------
    -- ОБЩИЕ ТИПЫ ДАННЫХ
    ----------------------------------------------------------------------------
    TYPE t_board IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

    TYPE t_node IS RECORD (
        board_state t_board,
        g_cost      NUMBER,
        h_cost      NUMBER
    );

    TYPE t_path IS TABLE OF t_node INDEX BY PLS_INTEGER;

    ----------------------------------------------------------------------------
    -- ПРОЦЕДУРЫ И ФУНКЦИИ API
    ----------------------------------------------------------------------------

    -- Блок авторизации
    FUNCTION register_user(p_username IN VARCHAR2, p_password_hash IN VARCHAR2) RETURN NUMBER;
    FUNCTION login_user(p_username IN VARCHAR2, p_password_hash IN VARCHAR2) RETURN NUMBER;

    -- Блок управления игрой
    FUNCTION check_active_session(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB;
    FUNCTION start_new_game(
        p_user_id IN USERS.USER_ID%TYPE, p_board_size IN NUMBER,
        p_shuffle_moves IN NUMBER, p_game_mode IN VARCHAR2,
        p_image_url IN VARCHAR2, p_is_daily_challenge IN BOOLEAN,
        p_force_new IN BOOLEAN,
        p_replay_game_id IN GAMES.GAME_ID%TYPE DEFAULT NULL
    ) RETURN CLOB;
    FUNCTION process_move(p_session_id IN GAMES.GAME_ID%TYPE, p_tile_value IN NUMBER) RETURN CLOB;
    FUNCTION undo_move(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB;
    FUNCTION redo_move(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB;
    PROCEDURE abandon_game(p_session_id IN GAMES.GAME_ID%TYPE);
    
    -- Блок подсказок, рейтингов и изображений
    FUNCTION get_hint(p_session_id IN GAMES.GAME_ID%TYPE) RETURN VARCHAR2;
    FUNCTION get_leaderboards(p_filter_size IN NUMBER, p_filter_difficulty IN NUMBER) RETURN CLOB;
    FUNCTION get_game_history(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB;
    
    FUNCTION save_user_image(
        p_user_id IN USERS.USER_ID%TYPE, 
        p_mime_type IN VARCHAR2, 
        p_image_data IN BLOB,
        p_image_hash IN VARCHAR2
    ) RETURN NUMBER;
    FUNCTION get_user_images(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB;
    
    -- ИСПРАВЛЕНО: Заменяем зависимость от типа колонки на базовый тип NUMBER
    PROCEDURE get_user_image_data(
        p_image_id IN NUMBER, -- Было: USER_IMAGES.IMAGE_ID%TYPE
        o_mime_type OUT VARCHAR2, -- Было: USER_IMAGES.MIME_TYPE%TYPE
        o_image_data OUT BLOB
    );

    FUNCTION get_default_images RETURN CLOB;
    
    -- ИСПРАВЛЕНО: Заменяем зависимость от типа колонки на базовый тип NUMBER
    PROCEDURE get_default_image_data(
        p_image_id IN NUMBER, -- Было: DEFAULT_IMAGES.IMAGE_ID%TYPE
        o_mime_type OUT VARCHAR2, -- Было: DEFAULT_IMAGES.MIME_TYPE%TYPE
        o_image_data OUT BLOB
    );

    -- Блок для планировщика
    PROCEDURE create_daily_challenge;

END GAME_MANAGER_PKG;
/

-- 2. ТЕЛО ЕДИНОГО ПАКЕТА
CREATE OR REPLACE PACKAGE BODY GAME_MANAGER_PKG AS

    ----------------------------------------------------------------------------
    -- ПРИВАТНЫЕ УТИЛИТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ДЛЯ СОЛВЕРА
    ----------------------------------------------------------------------------
    g_target_positions GAME_MANAGER_PKG.t_board;
    g_board_size NUMBER;

    FUNCTION state_to_table(p_state IN VARCHAR2) RETURN GAME_MANAGER_PKG.t_board;
    FUNCTION table_to_state(p_table IN GAME_MANAGER_PKG.t_board) RETURN VARCHAR2;
    FUNCTION get_game_state_json(p_game_id IN NUMBER) RETURN CLOB;
    FUNCTION calculate_heuristic(p_board GAME_MANAGER_PKG.t_board) RETURN NUMBER;
    PROCEDURE init_target_positions(p_target_board GAME_MANAGER_PKG.t_board, p_size NUMBER);
    FUNCTION get_next_best_move(p_board_state IN VARCHAR2, p_target_board_state IN VARCHAR2, p_board_size_param  IN NUMBER) RETURN NUMBER;
    
    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ БЛОКА АВТОРИЗАЦИИ
    ----------------------------------------------------------------------------
    FUNCTION register_user(
        p_username IN VARCHAR2,
        p_password_hash IN VARCHAR2
    ) RETURN NUMBER AS
        l_user_id NUMBER;
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_count FROM USERS WHERE USERNAME = p_username;
        IF l_count > 0 THEN
            RETURN -1;
        END IF;
        INSERT INTO USERS (USERNAME, PASSWORD_HASH)
        VALUES (p_username, p_password_hash)
        RETURNING USER_ID INTO l_user_id;
        COMMIT;
        RETURN l_user_id;
    END register_user;

    FUNCTION login_user(
        p_username IN VARCHAR2,
        p_password_hash IN VARCHAR2
    ) RETURN NUMBER AS
        l_user_id NUMBER;
    BEGIN
        SELECT USER_ID INTO l_user_id
        FROM USERS
        WHERE USERNAME = p_username AND PASSWORD_HASH = p_password_hash;
        RETURN l_user_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
    END login_user;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ БЛОКА УПРАВЛЕНИЯ ИГРОЙ
    ----------------------------------------------------------------------------
    FUNCTION check_active_session(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB AS
        l_game GAMES%ROWTYPE;
        l_json_clob CLOB;
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE USER_ID = p_user_id AND STATUS = 'ACTIVE';
        l_json_clob := get_game_state_json(l_game.GAME_ID);
        l_json_clob := SUBSTR(l_json_clob, 1, LENGTH(l_json_clob) - 1);
        l_json_clob := l_json_clob || ',"active_session_found":true}';
        RETURN l_json_clob;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN '{"active_session_found":false}';
    END check_active_session;

    FUNCTION start_new_game(
        p_user_id IN USERS.USER_ID%TYPE, p_board_size IN NUMBER,
        p_shuffle_moves IN NUMBER, p_game_mode IN VARCHAR2,
        p_image_url IN VARCHAR2, p_is_daily_challenge IN BOOLEAN,
        p_force_new IN BOOLEAN, p_replay_game_id IN GAMES.GAME_ID%TYPE DEFAULT NULL
    ) RETURN CLOB AS
        l_active_session_json CLOB;
        l_game_id GAMES.GAME_ID%TYPE;
        l_start_state VARCHAR2(1000);
        l_target_state VARCHAR2(1000);
        l_size PLS_INTEGER := p_board_size;
        l_shuffles PLS_INTEGER := p_shuffle_moves;
        l_is_daily_numeric NUMBER := 0;
        l_old_game GAMES%ROWTYPE;
    BEGIN
        IF NOT p_force_new THEN
            l_active_session_json := check_active_session(p_user_id);
            IF INSTR(l_active_session_json, '"active_session_found":true') > 0 THEN
                RETURN l_active_session_json;
            END IF;
        END IF;

        DELETE FROM GAMES WHERE USER_ID = p_user_id AND STATUS = 'ACTIVE';

        IF p_replay_game_id IS NOT NULL THEN
            SELECT * INTO l_old_game FROM GAMES WHERE GAME_ID = p_replay_game_id AND USER_ID = p_user_id;
            SELECT BOARD_STATE INTO l_start_state FROM MOVE_HISTORY WHERE GAME_ID = p_replay_game_id AND MOVE_ORDER = 0;
            l_size := l_old_game.BOARD_SIZE;
            l_shuffles := l_old_game.DIFFICULTY_LEVEL;
            l_target_state := l_old_game.TARGET_STATE;
            l_is_daily_numeric := l_old_game.IS_DAILY_CHALLENGE;
        ELSE
            IF p_is_daily_challenge THEN
                DECLARE l_daily DAILY_CHALLENGES%ROWTYPE;
                BEGIN
                    SELECT * INTO l_daily FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = TRUNC(SYSDATE);
                    l_size := l_daily.BOARD_SIZE;
                    l_shuffles := l_daily.SHUFFLE_MOVES;
                    l_target_state := l_daily.TARGET_STATE;
                    l_is_daily_numeric := 1;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        l_is_daily_numeric := 0;
                END;
            END IF;
            
            IF l_is_daily_numeric = 0 THEN
                l_target_state := '';
                FOR i IN 1..(l_size*l_size - 1) LOOP l_target_state := l_target_state || i || ','; END LOOP;
                l_target_state := l_target_state || '0';
            END IF;
            
            LOOP
                DECLARE
                    l_board GAME_MANAGER_PKG.t_board := state_to_table(l_target_state);
                    l_empty_idx PLS_INTEGER := l_size*l_size;
                BEGIN
                    FOR i IN 1..l_shuffles LOOP
                        DECLARE
                            l_possible_moves GAME_MANAGER_PKG.t_board; l_move_to_idx PLS_INTEGER;
                            l_rand_move PLS_INTEGER; l_temp NUMBER; k PLS_INTEGER := 1;
                        BEGIN
                            IF MOD(l_empty_idx - 1, l_size) > 0 THEN l_possible_moves(k) := l_empty_idx - 1; k := k + 1; END IF;
                            IF MOD(l_empty_idx - 1, l_size) < l_size - 1 THEN l_possible_moves(k) := l_empty_idx + 1; k := k + 1; END IF;
                            IF l_empty_idx - l_size > 0 THEN l_possible_moves(k) := l_empty_idx - l_size; k := k + 1; END IF;
                            IF l_empty_idx + l_size <= l_size*l_size THEN l_possible_moves(k) := l_empty_idx + l_size; END IF;
                            l_rand_move := TRUNC(DBMS_RANDOM.VALUE(1, l_possible_moves.COUNT + 1));
                            l_move_to_idx := l_possible_moves(l_rand_move); l_temp := l_board(l_move_to_idx);
                            l_board(l_move_to_idx) := l_board(l_empty_idx); l_board(l_empty_idx) := l_temp;
                            l_empty_idx := l_move_to_idx;
                        END;
                    END LOOP;
                    l_start_state := table_to_state(l_board);
                END;
                EXIT WHEN l_start_state != l_target_state;
            END LOOP;
        END IF;
        
        INSERT INTO GAMES (USER_ID, STATUS, BOARD_SIZE, DIFFICULTY_LEVEL, GAME_MODE, IMAGE_URL, IS_DAILY_CHALLENGE, BOARD_STATE, TARGET_STATE, START_TIME)
        VALUES (p_user_id, 'ACTIVE', l_size, l_shuffles, p_game_mode, p_image_url, l_is_daily_numeric, l_start_state, l_target_state, CURRENT_TIMESTAMP)
        RETURNING GAME_ID INTO l_game_id;
        
        INSERT INTO MOVE_HISTORY (GAME_ID, BOARD_STATE, MOVE_ORDER) VALUES (l_game_id, l_start_state, 0);
        COMMIT;
        RETURN get_game_state_json(l_game_id);
    END start_new_game;

    FUNCTION process_move(p_session_id IN GAMES.GAME_ID%TYPE, p_tile_value IN NUMBER) RETURN CLOB AS
        l_game GAMES%ROWTYPE; l_board GAME_MANAGER_PKG.t_board;
        l_empty_idx PLS_INTEGER; l_tile_idx PLS_INTEGER; l_is_adjacent BOOLEAN := FALSE;
        l_new_board_state VARCHAR2(1000); l_stars NUMBER := 0;
        l_duration NUMBER; l_final_json CLOB;
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id AND STATUS = 'ACTIVE';
        l_board := state_to_table(l_game.BOARD_STATE);
        FOR i IN l_board.FIRST..l_board.LAST LOOP
            IF l_board(i) = 0 THEN l_empty_idx := i; END IF; IF l_board(i) = p_tile_value THEN l_tile_idx := i; END IF;
        END LOOP;
        IF (ABS(l_tile_idx - l_empty_idx) = 1 AND TRUNC((l_tile_idx-1)/l_game.BOARD_SIZE) = TRUNC((l_empty_idx-1)/l_game.BOARD_SIZE)) OR
           (ABS(l_tile_idx - l_empty_idx) = l_game.BOARD_SIZE) THEN l_is_adjacent := TRUE; END IF;
        
        IF l_is_adjacent THEN
            l_board(l_empty_idx) := l_board(l_tile_idx); l_board(l_tile_idx) := 0;
            l_new_board_state := table_to_state(l_board);
            
            IF l_new_board_state = l_game.TARGET_STATE THEN
                l_duration := ROUND((CAST(CURRENT_TIMESTAMP AS DATE) - CAST(l_game.START_TIME AS DATE)) * 86400);
                DECLARE l_opt_moves NUMBER; BEGIN SELECT OPTIMAL_MOVES INTO l_opt_moves FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = TRUNC(l_game.START_TIME); IF l_game.MOVE_COUNT + 1 <= l_opt_moves THEN l_stars := 3; ELSIF l_game.MOVE_COUNT + 1 <= l_opt_moves * 1.1 THEN l_stars := 2; ELSE l_stars := 1; END IF; EXCEPTION WHEN NO_DATA_FOUND THEN l_stars := 1; END;
                
                UPDATE GAMES SET
                    STATUS = 'SOLVED', MOVE_COUNT = l_game.MOVE_COUNT + 1, BOARD_STATE = l_new_board_state,
                    COMPLETED_AT = CURRENT_TIMESTAMP, DURATION_SECONDS = l_duration, STARS_EARNED = l_stars
                WHERE GAME_ID = p_session_id;

                SELECT JSON_OBJECT(
                    'sessionId' VALUE p_session_id, 'boardSize' VALUE l_game.BOARD_SIZE,
                    'boardState' VALUE JSON_QUERY('[' || l_new_board_state || ']', '$'),
                    'moves' VALUE l_game.MOVE_COUNT + 1, 'startTime' VALUE TO_CHAR(l_game.START_TIME, 'YYYY-MM-DD"T"HH24:MI:SS'),
                    'status' VALUE 'SOLVED', 'imageUrl' VALUE l_game.IMAGE_URL, 'stars' VALUE l_stars,
                    'gameMode' VALUE l_game.GAME_MODE
                ) INTO l_final_json FROM dual;
                
                COMMIT;
                RETURN l_final_json;
            ELSE
                UPDATE GAMES SET BOARD_STATE = l_new_board_state, MOVE_COUNT = l_game.MOVE_COUNT + 1, REDO_STACK = NULL
                WHERE GAME_ID = p_session_id;
                INSERT INTO MOVE_HISTORY (GAME_ID, BOARD_STATE, MOVE_ORDER) VALUES (p_session_id, l_new_board_state, l_game.MOVE_COUNT + 1);
            END IF;
            COMMIT;
        END IF;
        RETURN get_game_state_json(p_session_id);
    END process_move;

    PROCEDURE abandon_game(p_session_id IN GAMES.GAME_ID%TYPE) AS
        l_duration NUMBER; l_start_time TIMESTAMP;
    BEGIN
        SELECT START_TIME INTO l_start_time FROM GAMES WHERE GAME_ID = p_session_id;
        l_duration := ROUND((CAST(CURRENT_TIMESTAMP AS DATE) - CAST(l_start_time AS DATE)) * 86400);
        UPDATE GAMES SET STATUS = 'ABANDONED', COMPLETED_AT = CURRENT_TIMESTAMP, DURATION_SECONDS = l_duration
        WHERE GAME_ID = p_session_id;
        COMMIT;
    END abandon_game;
    
FUNCTION undo_move(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB AS
    l_game GAMES%ROWTYPE;
    l_previous_state MOVE_HISTORY.BOARD_STATE%TYPE;
BEGIN
    SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id AND STATUS = 'ACTIVE';

    IF l_game.MOVE_COUNT > 0 THEN
        SELECT BOARD_STATE INTO l_previous_state
        FROM MOVE_HISTORY
        WHERE GAME_ID = p_session_id AND MOVE_ORDER = l_game.MOVE_COUNT - 1;

        UPDATE GAMES
        SET BOARD_STATE = l_previous_state,
            MOVE_COUNT = l_game.MOVE_COUNT - 1,
            -- ИСПРАВЛЕНО: Явно преобразуем VARCHAR2 в CLOB для совместимости типов
            REDO_STACK = CASE
                         WHEN l_game.REDO_STACK IS NULL
                         THEN TO_CLOB(l_game.BOARD_STATE) -- Преобразование здесь
                         ELSE l_game.REDO_STACK || '|' || l_game.BOARD_STATE
                       END
        WHERE GAME_ID = p_session_id;

        DELETE FROM MOVE_HISTORY
        WHERE GAME_ID = p_session_id AND MOVE_ORDER = l_game.MOVE_COUNT;
        
        COMMIT;
    END IF;

    RETURN get_game_state_json(p_session_id);
END undo_move;

    FUNCTION redo_move(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB AS
        l_game GAMES%ROWTYPE; l_redo_state VARCHAR2(2000); l_new_redo_stack CLOB;
        l_last_pipe_pos PLS_INTEGER;
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id AND STATUS = 'ACTIVE';
        IF l_game.REDO_STACK IS NOT NULL THEN
            l_last_pipe_pos := INSTR(l_game.REDO_STACK, '|', -1);
            IF l_last_pipe_pos = 0 THEN l_redo_state := l_game.REDO_STACK; l_new_redo_stack := NULL;
            ELSE l_redo_state := SUBSTR(l_game.REDO_STACK, l_last_pipe_pos + 1); l_new_redo_stack := SUBSTR(l_game.REDO_STACK, 1, l_last_pipe_pos - 1); END IF;
            UPDATE GAMES SET BOARD_STATE = l_redo_state, MOVE_COUNT = l_game.MOVE_COUNT + 1, REDO_STACK = l_new_redo_stack
            WHERE GAME_ID = p_session_id;
            INSERT INTO MOVE_HISTORY (GAME_ID, BOARD_STATE, MOVE_ORDER) VALUES (p_session_id, l_redo_state, l_game.MOVE_COUNT + 1);
            COMMIT;
        END IF;
        RETURN get_game_state_json(p_session_id);
    END redo_move;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ БЛОКА ПОДСКАЗОК, РЕЙТИНГОВ И ИЗОБРАЖЕНИЙ
    ----------------------------------------------------------------------------
    FUNCTION get_leaderboards(p_filter_size IN NUMBER, p_filter_difficulty IN NUMBER) RETURN CLOB AS
        l_json CLOB; l_query VARCHAR2(4000);
    BEGIN
        l_query := 'SELECT JSON_ARRAYAGG(JSON_OBJECT(''user'' VALUE u.USERNAME, ''total_stars'' VALUE SUM(a.STARS_EARNED)) ORDER BY SUM(a.STARS_EARNED) DESC RETURNING CLOB) FROM GAMES a JOIN USERS u ON a.USER_ID = u.USER_ID WHERE u.USERNAME != ''player1'' AND a.STATUS = ''SOLVED'' ';
        IF p_filter_size > 0 THEN l_query := l_query || ' AND a.BOARD_SIZE = :1'; END IF;
        IF p_filter_difficulty > 0 THEN IF INSTR(l_query, ':1') > 0 THEN l_query := l_query || ' AND a.DIFFICULTY_LEVEL = :2'; ELSE l_query := l_query || ' AND a.DIFFICULTY_LEVEL = :1'; END IF; END IF;
        l_query := l_query || ' GROUP BY u.USERNAME';
        IF p_filter_size > 0 AND p_filter_difficulty > 0 THEN EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_size, p_filter_difficulty;
        ELSIF p_filter_size > 0 THEN EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_size;
        ELSIF p_filter_difficulty > 0 THEN EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_difficulty;
        ELSE EXECUTE IMMEDIATE l_query INTO l_json;
        END IF;
        RETURN JSON_OBJECT('leaderboard' VALUE JSON_QUERY(NVL(l_json, '[]'), '$'));
    END get_leaderboards;
    
    FUNCTION get_game_history(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB AS
        l_json CLOB;
    BEGIN
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT( 'gameId' VALUE g.GAME_ID, 'date' VALUE TO_CHAR(g.COMPLETED_AT, 'DD.MM.YYYY HH24:MI'),
                         'size' VALUE g.BOARD_SIZE, 'moves' VALUE g.MOVE_COUNT, 'time' VALUE g.DURATION_SECONDS,
                         'status' VALUE g.STATUS, 'stars' VALUE g.STARS_EARNED
            ) ORDER BY g.COMPLETED_AT DESC
        )
        INTO l_json FROM GAMES g WHERE g.USER_ID = p_user_id AND g.STATUS IN ('SOLVED', 'ABANDONED');
        RETURN NVL(l_json, '[]');
    END get_game_history;

    -- НЕДОСТАЮЩИЕ ПРОЦЕДУРЫ ДЛЯ РАБОТЫ С КАРТИНКАМИ
    FUNCTION save_user_image(
        p_user_id IN USERS.USER_ID%TYPE, 
        p_mime_type IN VARCHAR2, 
        p_image_data IN BLOB,
        p_image_hash IN VARCHAR2
    ) RETURN NUMBER AS
        l_count NUMBER;
    BEGIN
        -- Проверяем, есть ли уже картинка с таким хешем у этого пользователя
        SELECT COUNT(*)
        INTO l_count
        FROM USER_IMAGES
        WHERE USER_ID = p_user_id AND IMAGE_HASH = p_image_hash;
    
        -- Если найдена (l_count > 0), то это дубликат. Возвращаем 0.
        IF l_count > 0 THEN
            RETURN 0; -- 0 означает "дубликат"
        END IF;
    
        -- Если дубликата нет, вставляем новую запись
        INSERT INTO USER_IMAGES (USER_ID, MIME_TYPE, IMAGE_DATA, IMAGE_NAME, IMAGE_HASH)
        VALUES (p_user_id, p_mime_type, p_image_data, NULL, p_image_hash);
    
        COMMIT;
        RETURN 1; -- 1 означает "успешно загружено"
    EXCEPTION
        -- На случай, если уникальное ограничение сработает из-за гонки потоков
        WHEN DUP_VAL_ON_INDEX THEN
            RETURN 0;
    END save_user_image;

    FUNCTION get_user_images(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB AS
        l_json CLOB;
    BEGIN
        SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE IMAGE_ID) ORDER BY UPLOADED_AT DESC)
        INTO l_json FROM USER_IMAGES WHERE USER_ID = p_user_id;
        RETURN NVL(l_json, '[]');
    END get_user_images;

    PROCEDURE get_user_image_data(p_image_id IN NUMBER, o_mime_type OUT VARCHAR2, o_image_data OUT BLOB) AS
        l_owner_id NUMBER;
        l_user_id NUMBER; -- Предполагаем, что ID текущего пользователя можно получить
    BEGIN
        -- Этот блок требует способа получить ID текущего пользователя,
        -- но для простоты реализуем прямой доступ, полагаясь на проверку в Python
        SELECT MIME_TYPE, IMAGE_DATA
        INTO o_mime_type, o_image_data
        FROM USER_IMAGES
        WHERE IMAGE_ID = p_image_id;
    END get_user_image_data;
    
    FUNCTION get_default_images RETURN CLOB AS
        l_json CLOB;
    BEGIN
        SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE IMAGE_ID, 'name' VALUE IMAGE_NAME) ORDER BY IMAGE_ID)
        INTO l_json FROM USER_IMAGES WHERE USER_ID IS NULL;
        RETURN NVL(l_json, '[]');
    END get_default_images;
    
    PROCEDURE get_default_image_data(p_image_id IN NUMBER, o_mime_type OUT VARCHAR2, o_image_data OUT BLOB) AS
    BEGIN
        SELECT MIME_TYPE, IMAGE_DATA
        INTO o_mime_type, o_image_data
        FROM USER_IMAGES
        WHERE IMAGE_ID = p_image_id AND USER_ID IS NULL;
    END get_default_image_data;
    
    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ СОЛВЕРА
    ----------------------------------------------------------------------------
    FUNCTION search(
        p_path      IN OUT NOCOPY GAME_MANAGER_PKG.t_path, p_g_cost    IN NUMBER,
        p_threshold IN NUMBER, o_solution  OUT NOCOPY GAME_MANAGER_PKG.t_path
    ) RETURN NUMBER;
    
    FUNCTION get_hint(p_session_id IN GAMES.GAME_ID%TYPE) RETURN VARCHAR2 IS
        l_session GAMES%ROWTYPE;
        l_tile_to_move NUMBER;
    BEGIN
        SELECT * INTO l_session FROM GAMES WHERE GAME_ID = p_session_id;
        l_tile_to_move := get_next_best_move(
            p_board_state        => l_session.BOARD_STATE,
            p_target_board_state => l_session.TARGET_STATE,
            p_board_size_param   => l_session.BOARD_SIZE
        );
        RETURN JSON_OBJECT('hint' VALUE l_tile_to_move);
    END get_hint;
    
    PROCEDURE init_target_positions(p_target_board GAME_MANAGER_PKG.t_board, p_size NUMBER) IS
    BEGIN
        g_board_size := p_size;
        FOR i IN 1 .. p_target_board.COUNT LOOP
            IF p_target_board(i) != 0 THEN
                g_target_positions(p_target_board(i)) := i;
            END IF;
        END LOOP;
    END init_target_positions;

    FUNCTION is_state_in_path(p_path GAME_MANAGER_PKG.t_path, p_board GAME_MANAGER_PKG.t_board) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. p_path.COUNT LOOP
            IF table_to_state(p_path(i).board_state) = table_to_state(p_board) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END is_state_in_path;

    FUNCTION search(
        p_path      IN OUT NOCOPY GAME_MANAGER_PKG.t_path, p_g_cost    IN NUMBER,
        p_threshold IN NUMBER, o_solution  OUT NOCOPY GAME_MANAGER_PKG.t_path
    ) RETURN NUMBER IS
        l_current_node  GAME_MANAGER_PKG.t_node; l_f_cost        NUMBER;
        l_min_f         NUMBER := 999999; l_empty_idx     PLS_INTEGER;
    BEGIN
        l_current_node := p_path(p_path.COUNT);
        l_f_cost := p_g_cost + l_current_node.h_cost;
        IF l_f_cost > p_threshold THEN RETURN l_f_cost; END IF;
        IF l_current_node.h_cost = 0 THEN o_solution := p_path; RETURN -1; END IF;
        FOR i IN 1 .. l_current_node.board_state.COUNT LOOP
            IF l_current_node.board_state(i) = 0 THEN l_empty_idx := i; EXIT; END IF;
        END LOOP;
        DECLARE
            l_possible_moves GAME_MANAGER_PKG.t_board; k PLS_INTEGER := 1;
        BEGIN
            IF l_empty_idx - g_board_size > 0 THEN l_possible_moves(k) := l_empty_idx - g_board_size; k := k + 1; END IF;
            IF l_empty_idx + g_board_size <= g_board_size*g_board_size THEN l_possible_moves(k) := l_empty_idx + g_board_size; k := k + 1; END IF;
            IF MOD(l_empty_idx - 1, g_board_size) > 0 THEN l_possible_moves(k) := l_empty_idx - 1; k := k + 1; END IF;
            IF MOD(l_empty_idx - 1, g_board_size) < g_board_size - 1 THEN l_possible_moves(k) := l_empty_idx + 1; END IF;
            FOR i IN 1 .. l_possible_moves.COUNT LOOP
                DECLARE
                    l_next_board GAME_MANAGER_PKG.t_board; l_next_node  GAME_MANAGER_PKG.t_node;
                    l_temp       NUMBER; l_res        NUMBER;
                BEGIN
                    l_next_board := l_current_node.board_state;
                    l_temp := l_next_board(l_possible_moves(i));
                    l_next_board(l_possible_moves(i)) := 0; l_next_board(l_empty_idx) := l_temp;
                    IF NOT is_state_in_path(p_path, l_next_board) THEN
                        l_next_node.board_state := l_next_board;
                        l_next_node.g_cost := p_g_cost + 1;
                        l_next_node.h_cost := calculate_heuristic(l_next_board);
                        p_path(p_path.COUNT + 1) := l_next_node;
                        l_res := search(p_path, p_g_cost + 1, p_threshold, o_solution);
                        IF l_res = -1 THEN RETURN -1; END IF;
                        IF l_res < l_min_f THEN l_min_f := l_res; END IF;
                        p_path.DELETE(p_path.COUNT);
                    END IF;
                END;
            END LOOP;
        END;
        RETURN l_min_f;
    END search;

    FUNCTION get_next_best_move(
        p_board_state       IN VARCHAR2,
        p_target_board_state IN VARCHAR2,
        p_board_size_param  IN NUMBER
    ) RETURN NUMBER AS
        l_initial_board GAME_MANAGER_PKG.t_board := state_to_table(p_board_state);
        l_target_board  GAME_MANAGER_PKG.t_board := state_to_table(p_target_board_state);
        l_path          GAME_MANAGER_PKG.t_path; l_solution      GAME_MANAGER_PKG.t_path;
        l_initial_node  GAME_MANAGER_PKG.t_node; l_threshold     NUMBER;
        l_result        NUMBER; l_start_time    NUMBER;
    BEGIN
        init_target_positions(l_target_board, p_board_size_param);
        l_initial_node.board_state := l_initial_board;
        l_initial_node.g_cost := 0;
        l_initial_node.h_cost := calculate_heuristic(l_initial_board);
        l_path(1) := l_initial_node;
        l_threshold := l_initial_node.h_cost;
        l_start_time := DBMS_UTILITY.GET_TIME;
        LOOP
            l_result := search(l_path, 0, l_threshold, l_solution);
            IF l_result = -1 THEN EXIT; END IF;
            l_threshold := l_result;
            IF (DBMS_UTILITY.GET_TIME - l_start_time) > 300 THEN RETURN NULL; END IF;
        END LOOP;
        IF l_solution.COUNT > 1 THEN
            DECLARE
                l_board1 GAME_MANAGER_PKG.t_board := l_solution(1).board_state;
                l_board2 GAME_MANAGER_PKG.t_board := l_solution(2).board_state;
            BEGIN
                FOR i IN 1..l_board1.COUNT LOOP
                    IF l_board1(i) != 0 AND l_board2(i) = 0 THEN
                        RETURN l_board1(i);
                    END IF;
                END LOOP;
            END;
        END IF;
        RETURN NULL;
    END get_next_best_move;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ БЛОКА ПЛАНИРОВЩИКА
    ----------------------------------------------------------------------------
    PROCEDURE create_daily_challenge AS
        l_board_size    NUMBER; l_shuffle_moves NUMBER; l_target_state  VARCHAR2(1000);
        l_shuffled_board VARCHAR2(1000); l_optimal_moves NUMBER;
        l_board         GAME_MANAGER_PKG.t_board; l_empty_idx     PLS_INTEGER;
        l_solution      GAME_MANAGER_PKG.t_path; l_next_day      DATE := TRUNC(SYSDATE) + 1;
        l_count         NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_count FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = l_next_day;
        IF l_count > 0 THEN RETURN; END IF;
        l_board_size := TRUNC(DBMS_RANDOM.VALUE(3, 5));
        IF l_board_size = 3 THEN l_shuffle_moves := TRUNC(DBMS_RANDOM.VALUE(20, 31));
        ELSE l_shuffle_moves := TRUNC(DBMS_RANDOM.VALUE(40, 71)); END IF;
        l_target_state := '';
        FOR i IN 1..(l_board_size * l_board_size - 1) LOOP l_target_state := l_target_state || i || ','; END LOOP;
        l_target_state := l_target_state || '0';
        LOOP
            l_board := state_to_table(l_target_state); l_empty_idx := l_board_size * l_board_size;
            FOR i IN 1..l_shuffle_moves LOOP
                DECLARE
                    l_possible_moves GAME_MANAGER_PKG.t_board; l_move_to_idx PLS_INTEGER;
                    l_rand_move PLS_INTEGER; l_temp NUMBER; k PLS_INTEGER := 1;
                BEGIN
                    IF MOD(l_empty_idx - 1, l_board_size) > 0 THEN l_possible_moves(k) := l_empty_idx - 1; k := k + 1; END IF;
                    IF MOD(l_empty_idx - 1, l_board_size) < l_board_size - 1 THEN l_possible_moves(k) := l_empty_idx + 1; k := k + 1; END IF;
                    IF l_empty_idx - l_board_size > 0 THEN l_possible_moves(k) := l_empty_idx - l_board_size; k := k + 1; END IF;
                    IF l_empty_idx + l_board_size <= l_board_size*l_board_size THEN l_possible_moves(k) := l_empty_idx + l_board_size; END IF;
                    l_rand_move := TRUNC(DBMS_RANDOM.VALUE(1, l_possible_moves.COUNT + 1));
                    l_move_to_idx := l_possible_moves(l_rand_move); l_temp := l_board(l_move_to_idx);
                    l_board(l_move_to_idx) := l_board(l_empty_idx); l_board(l_empty_idx) := l_temp;
                    l_empty_idx := l_move_to_idx;
                END;
            END LOOP;
            l_shuffled_board := table_to_state(l_board);
            EXIT WHEN l_shuffled_board != l_target_state;
        END LOOP;
        DECLARE
            l_path GAME_MANAGER_PKG.t_path; l_initial_node GAME_MANAGER_PKG.t_node;
            l_threshold NUMBER; l_result NUMBER;
        BEGIN
            init_target_positions(state_to_table(l_target_state), l_board_size);
            l_initial_node.board_state := state_to_table(l_shuffled_board);
            l_initial_node.g_cost := 0; l_initial_node.h_cost := calculate_heuristic(l_initial_node.board_state);
            l_path(1) := l_initial_node; l_threshold := l_initial_node.h_cost;
            LOOP
                l_result := search(l_path, 0, l_threshold, l_solution);
                IF l_result = -1 THEN EXIT; END IF;
                l_threshold := l_result;
                IF l_threshold > 80 THEN l_solution.DELETE; EXIT; END IF;
            END LOOP;
            l_optimal_moves := l_solution.COUNT - 1;
        END;
        INSERT INTO DAILY_CHALLENGES (CHALLENGE_DATE, BOARD_SIZE, SHUFFLE_MOVES, TARGET_STATE, OPTIMAL_MOVES)
        VALUES (l_next_day, l_board_size, l_shuffle_moves, l_target_state, l_optimal_moves);
        COMMIT;
    END create_daily_challenge;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ ПРИВАТНЫХ УТИЛИТ
    ----------------------------------------------------------------------------
    FUNCTION get_game_state_json(p_game_id IN NUMBER) RETURN CLOB IS
        l_json_clob CLOB; l_game GAMES%ROWTYPE;
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_game_id;
        SELECT JSON_OBJECT(
            'sessionId' VALUE l_game.GAME_ID, 'boardSize' VALUE l_game.BOARD_SIZE,
            'boardState' VALUE JSON_QUERY('[' || l_game.BOARD_STATE || ']', '$'),
            'moves' VALUE l_game.MOVE_COUNT, 'startTime' VALUE TO_CHAR(l_game.START_TIME, 'YYYY-MM-DD"T"HH24:MI:SS'),
            'status' VALUE l_game.STATUS, 'imageUrl' VALUE l_game.IMAGE_URL, 'stars' VALUE l_game.STARS_EARNED,
            'gameMode' VALUE l_game.GAME_MODE
        ) INTO l_json_clob FROM dual;
        RETURN l_json_clob;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN '{"status":"error", "message":"Session not found"}';
    END get_game_state_json;

    FUNCTION calculate_heuristic(p_board GAME_MANAGER_PKG.t_board) RETURN NUMBER IS
        l_heuristic NUMBER := 0; l_current_pos PLS_INTEGER; l_target_pos PLS_INTEGER;
        l_current_row PLS_INTEGER; l_current_col PLS_INTEGER; l_target_row PLS_INTEGER; l_target_col PLS_INTEGER;
    BEGIN
        FOR i IN 1 .. p_board.COUNT LOOP
            IF p_board(i) != 0 THEN
                l_current_pos := i; l_target_pos  := g_target_positions(p_board(i));
                l_current_row := TRUNC((l_current_pos - 1) / g_board_size);
                l_current_col := MOD(l_current_pos - 1, g_board_size);
                l_target_row  := TRUNC((l_target_pos - 1) / g_board_size);
                l_target_col  := MOD(l_target_pos - 1, g_board_size);
                l_heuristic := l_heuristic + ABS(l_current_row - l_target_row) + ABS(l_current_col - l_target_col);
            END IF;
        END LOOP;
        RETURN l_heuristic;
    END calculate_heuristic;

    FUNCTION state_to_table(p_state IN VARCHAR2) RETURN GAME_MANAGER_PKG.t_board IS
        l_string         VARCHAR2(32767) := p_state || ','; l_comma_index    PLS_INTEGER;
        l_start_index    PLS_INTEGER := 1; l_result_table   GAME_MANAGER_PKG.t_board;
        i                PLS_INTEGER := 1;
    BEGIN
        LOOP
            l_comma_index := INSTR(l_string, ',', l_start_index); EXIT WHEN l_comma_index = 0;
            l_result_table(i) := TO_NUMBER(SUBSTR(l_string, l_start_index, l_comma_index - l_start_index));
            l_start_index := l_comma_index + 1; i := i + 1;
        END LOOP;
        RETURN l_result_table;
    END state_to_table;

    FUNCTION table_to_state(p_table IN GAME_MANAGER_PKG.t_board) RETURN VARCHAR2 IS
        l_state VARCHAR2(32767);
    BEGIN
        IF p_table.COUNT = 0 THEN RETURN NULL; END IF;
        FOR i IN p_table.FIRST..p_table.LAST LOOP l_state := l_state || p_table(i) || ','; END LOOP;
        RETURN RTRIM(l_state, ',');
    END table_to_state;

END GAME_MANAGER_PKG;
/