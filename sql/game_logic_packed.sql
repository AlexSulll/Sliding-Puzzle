-- 1. СПЕЦИФИКАЦИЯ ЕДИНОГО ПАКЕТА
CREATE OR REPLACE PACKAGE GAME_MANAGER_PKG AS

    ----------------------------------------------------------------------------
    -- ОБЩИЕ ТИПЫ ДАННЫХ (ранее PUZZLE_TYPES_PKG)
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

    -- Блок авторизации (ранее AUTH_PKG)
    FUNCTION register_user(p_username IN VARCHAR2, p_password_hash IN VARCHAR2) RETURN NUMBER;
    FUNCTION login_user(p_username IN VARCHAR2, p_password_hash IN VARCHAR2) RETURN NUMBER;
    FUNCTION create_guest_user RETURN NUMBER;

    -- Блок управления игрой (ранее GAME_LOGIC_PKG)
    FUNCTION check_active_session(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB;
    FUNCTION start_new_game(
        p_user_id IN USERS.USER_ID%TYPE, p_board_size IN NUMBER,
        p_shuffle_moves IN NUMBER, p_game_mode IN VARCHAR2,
        p_image_url IN VARCHAR2, p_is_daily_challenge IN BOOLEAN,
        p_force_new IN BOOLEAN
    ) RETURN CLOB;
    FUNCTION process_move(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE, p_tile_value IN NUMBER) RETURN CLOB;
    FUNCTION undo_move(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) RETURN CLOB;
    FUNCTION redo_move(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) RETURN CLOB;
    PROCEDURE abandon_game(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE);
    
    -- Блок подсказок и рейтингов
    FUNCTION get_hint(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) RETURN VARCHAR2;
    FUNCTION get_leaderboards(p_filter_size IN NUMBER, p_filter_difficulty IN NUMBER) RETURN CLOB;

END GAME_MANAGER_PKG;
/


-- 2. ТЕЛО ЕДИНОГО ПАКЕТА
CREATE OR REPLACE PACKAGE BODY GAME_MANAGER_PKG AS

    ----------------------------------------------------------------------------
    -- ПРИВАТНЫЕ УТИЛИТЫ И ПЕРЕМЕННЫЕ
    ----------------------------------------------------------------------------
    g_target_positions GAME_MANAGER_PKG.t_board;
    g_board_size NUMBER;

    FUNCTION state_to_table(p_state IN VARCHAR2) RETURN GAME_MANAGER_PKG.t_board;
    FUNCTION table_to_state(p_table IN GAME_MANAGER_PKG.t_board) RETURN VARCHAR2;
    FUNCTION get_game_state_json(p_session_id IN NUMBER) RETURN CLOB;
    FUNCTION calculate_heuristic(p_board GAME_MANAGER_PKG.t_board) RETURN NUMBER;
    
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
            RETURN -1; -- Пользователь уже существует
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

    FUNCTION create_guest_user RETURN NUMBER AS
        l_user_id NUMBER;
        l_guest_name VARCHAR2(50);
    BEGIN
        l_guest_name := 'guest_' || users_seq.NEXTVAL;
        INSERT INTO USERS (USERNAME, PASSWORD_HASH)
        VALUES (l_guest_name, 'GUEST_NO_LOGIN')
        RETURNING USER_ID INTO l_user_id;
        COMMIT;
        RETURN l_user_id;
    END create_guest_user;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ БЛОКА УПРАВЛЕНИЯ ИГРОЙ
    ----------------------------------------------------------------------------
    FUNCTION check_active_session(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB AS
        l_session GAME_SESSIONS%ROWTYPE;
        l_json_clob CLOB;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE USER_ID = p_user_id AND STATUS = 'ACTIVE';
        l_json_clob := get_game_state_json(l_session.SESSION_ID);
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
        p_force_new IN BOOLEAN
    ) RETURN CLOB AS
        l_active_session_json CLOB;
        l_session_id GAME_SESSIONS.SESSION_ID%TYPE;
        l_board GAME_MANAGER_PKG.t_board;
        l_target_state VARCHAR2(1000);
        l_empty_idx PLS_INTEGER;
        l_size PLS_INTEGER := p_board_size;
        l_shuffles PLS_INTEGER := p_shuffle_moves;
        l_start_state VARCHAR2(1000);
        l_daily DAILY_CHALLENGES%ROWTYPE;
    BEGIN
        IF NOT p_force_new THEN
            l_active_session_json := check_active_session(p_user_id);
            IF INSTR(l_active_session_json, '"active_session_found":true') > 0 THEN
                RETURN l_active_session_json;
            END IF;
        END IF;

        DELETE FROM GAME_SESSIONS WHERE USER_ID = p_user_id AND STATUS = 'ACTIVE';

        IF p_is_daily_challenge THEN
            SELECT * INTO l_daily FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = TRUNC(SYSDATE);
            l_size := l_daily.BOARD_SIZE;
            l_shuffles := l_daily.SHUFFLE_MOVES;
            l_target_state := l_daily.TARGET_STATE;
        ELSE
            l_target_state := '';
            FOR i IN 1..(l_size*l_size - 1) LOOP
                l_target_state := l_target_state || i || ',';
            END LOOP;
            l_target_state := l_target_state || '0';
        END IF;
        
        -- НОВАЯ ЛОГИКА: Цикл для гарантии, что начальное состояние не равно целевому
        LOOP
            l_board := state_to_table(l_target_state);
            l_empty_idx := l_size*l_size;

            FOR i IN 1..l_shuffles LOOP
                DECLARE
                    l_possible_moves GAME_MANAGER_PKG.t_board;
                    l_move_to_idx PLS_INTEGER;
                    l_rand_move PLS_INTEGER;
                    l_temp NUMBER;
                    k PLS_INTEGER := 1;
                BEGIN
                    IF MOD(l_empty_idx - 1, l_size) > 0 THEN l_possible_moves(k) := l_empty_idx - 1; k := k + 1; END IF;
                    IF MOD(l_empty_idx - 1, l_size) < l_size - 1 THEN l_possible_moves(k) := l_empty_idx + 1; k := k + 1; END IF;
                    IF l_empty_idx - l_size > 0 THEN l_possible_moves(k) := l_empty_idx - l_size; k := k + 1; END IF;
                    IF l_empty_idx + l_size <= l_size*l_size THEN l_possible_moves(k) := l_empty_idx + l_size; END IF;
                    
                    l_rand_move := TRUNC(DBMS_RANDOM.VALUE(1, l_possible_moves.COUNT + 1));
                    l_move_to_idx := l_possible_moves(l_rand_move);
                    l_temp := l_board(l_move_to_idx);
                    l_board(l_move_to_idx) := l_board(l_empty_idx);
                    l_board(l_empty_idx) := l_temp;
                    l_empty_idx := l_move_to_idx;
                END;
            END LOOP;
            
            l_start_state := table_to_state(l_board);
            
            -- Выходим из цикла, если сгенерированное поле НЕ равно целевому
            EXIT WHEN l_start_state != l_target_state;
        END LOOP;
        
        -- ИСПРАВЛЕНО: Сохраняем изначальную сложность в сессию
        INSERT INTO GAME_SESSIONS (USER_ID, BOARD_SIZE, TARGET_STATE, GAME_MODE, IMAGE_URL, BOARD_STATE, REDO_STACK, DIFFICULTY_LEVEL)
        VALUES (p_user_id, l_size, l_target_state, p_game_mode, p_image_url, l_start_state, NULL, p_shuffle_moves)
        RETURNING SESSION_ID INTO l_session_id;

        INSERT INTO MOVE_HISTORY (SESSION_ID, BOARD_STATE, MOVE_ORDER)
        VALUES (l_session_id, l_start_state, 0);
        
        COMMIT;
        RETURN get_game_state_json(l_session_id);
    END start_new_game;

    -- ИСПРАВЛЕННАЯ ФУНКЦИЯ process_move
    FUNCTION process_move(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE, p_tile_value IN NUMBER) RETURN CLOB AS
        l_session GAME_SESSIONS%ROWTYPE;
        l_board GAME_MANAGER_PKG.t_board;
        l_empty_idx PLS_INTEGER;
        l_tile_idx PLS_INTEGER;
        l_size PLS_INTEGER;
        l_is_adjacent BOOLEAN := FALSE;
        l_new_board_state VARCHAR2(1000);
        l_stars NUMBER := 0;
        l_is_daily BOOLEAN;
        l_is_daily_numeric NUMBER;
        l_duration NUMBER;
        l_final_json CLOB;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id AND STATUS = 'ACTIVE';
        l_board := state_to_table(l_session.BOARD_STATE);
        l_size := l_session.BOARD_SIZE;

        FOR i IN l_board.FIRST..l_board.LAST LOOP
            IF l_board(i) = 0 THEN l_empty_idx := i; END IF;
            IF l_board(i) = p_tile_value THEN l_tile_idx := i; END IF;
        END LOOP;
        
        IF (ABS(l_tile_idx - l_empty_idx) = 1 AND TRUNC((l_tile_idx-1)/l_size) = TRUNC((l_empty_idx-1)/l_size)) OR
           (ABS(l_tile_idx - l_empty_idx) = l_size) THEN
            l_is_adjacent := TRUE;
        END IF;

        IF l_is_adjacent THEN
            l_board(l_empty_idx) := l_board(l_tile_idx);
            l_board(l_tile_idx) := 0;
            l_new_board_state := table_to_state(l_board);
            l_session.MOVE_COUNT := l_session.MOVE_COUNT + 1;

            IF l_new_board_state = l_session.TARGET_STATE THEN
                DECLARE
                    l_opt_moves NUMBER;
                BEGIN
                    SELECT OPTIMAL_MOVES INTO l_opt_moves FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = TRUNC(l_session.START_TIME);
                    l_is_daily := TRUE;
                    IF l_session.MOVE_COUNT <= l_opt_moves THEN l_stars := 3;
                    ELSIF l_session.MOVE_COUNT <= l_opt_moves * 1.1 THEN l_stars := 2;
                    ELSE l_stars := 1;
                    END IF;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        l_is_daily := FALSE;
                        l_stars := 1;
                END;

                IF l_is_daily THEN l_is_daily_numeric := 1; ELSE l_is_daily_numeric := 0; END IF;
                
                l_duration := ROUND((CAST(CURRENT_TIMESTAMP AS DATE) - CAST(l_session.START_TIME AS DATE)) * 86400);

                SELECT JSON_OBJECT(
                    'sessionId' VALUE l_session.SESSION_ID, 'boardSize' VALUE l_session.BOARD_SIZE,
                    'boardState' VALUE JSON_QUERY('[' || l_new_board_state || ']', '$'),
                    'moves' VALUE l_session.MOVE_COUNT, 'startTime' VALUE TO_CHAR(l_session.START_TIME, 'YYYY-MM-DD"T"HH24:MI:SS'),
                    'status' VALUE 'SOLVED', 'imageUrl' VALUE l_session.IMAGE_URL, 'stars' VALUE l_stars
                ) INTO l_final_json FROM dual;

                -- ИСПРАВЛЕНО: В архив сохраняется сложность из сессии, а не кол-во ходов.
                INSERT INTO GAME_ARCHIVE (USER_ID, BOARD_SIZE, MOVES_MADE, DURATION_SECONDS, RESULT, GAME_MODE, STARS_EARNED, IS_DAILY_CHALLENGE, DIFFICULTY_LEVEL)
                VALUES (l_session.USER_ID, l_session.BOARD_SIZE, l_session.MOVE_COUNT, l_duration, 'SOLVED', l_session.GAME_MODE, l_stars, l_is_daily_numeric, l_session.DIFFICULTY_LEVEL);
                
                DELETE FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;
                COMMIT;
                
                RETURN l_final_json;
            ELSE
                UPDATE GAME_SESSIONS SET BOARD_STATE = l_new_board_state, MOVE_COUNT = l_session.MOVE_COUNT, REDO_STACK = NULL
                WHERE SESSION_ID = p_session_id;
                INSERT INTO MOVE_HISTORY (SESSION_ID, BOARD_STATE, MOVE_ORDER) VALUES (p_session_id, l_new_board_state, l_session.MOVE_COUNT);
            END IF;
            COMMIT;
        END IF;
        RETURN get_game_state_json(p_session_id);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN get_game_state_json(p_session_id);
    END process_move;

    FUNCTION undo_move(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) RETURN CLOB AS
        l_session GAME_SESSIONS%ROWTYPE;
        l_previous_state MOVE_HISTORY.BOARD_STATE%TYPE;
        l_redo_stack CLOB;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;
        IF l_session.MOVE_COUNT > 0 THEN
            SELECT BOARD_STATE INTO l_previous_state FROM MOVE_HISTORY WHERE SESSION_ID = p_session_id AND MOVE_ORDER = l_session.MOVE_COUNT - 1;
            
            IF l_session.REDO_STACK IS NULL THEN
                l_redo_stack := l_session.BOARD_STATE;
            ELSE
                l_redo_stack := l_session.REDO_STACK || '|' || l_session.BOARD_STATE;
            END IF;

            DELETE FROM MOVE_HISTORY WHERE SESSION_ID = p_session_id AND MOVE_ORDER = l_session.MOVE_COUNT;
            
            UPDATE GAME_SESSIONS
            SET BOARD_STATE = l_previous_state, MOVE_COUNT = l_session.MOVE_COUNT - 1, REDO_STACK = l_redo_stack
            WHERE SESSION_ID = p_session_id;
            
            COMMIT;
        END IF;
        RETURN get_game_state_json(p_session_id);
    END undo_move;

    FUNCTION redo_move(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) RETURN CLOB AS
        l_session GAME_SESSIONS%ROWTYPE;
        l_redo_state VARCHAR2(2000);
        l_new_redo_stack CLOB;
        l_last_pipe_pos PLS_INTEGER;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;
        
        IF l_session.REDO_STACK IS NOT NULL THEN
            l_last_pipe_pos := INSTR(l_session.REDO_STACK, '|', -1);
            
            IF l_last_pipe_pos = 0 THEN
                l_redo_state := l_session.REDO_STACK;
                l_new_redo_stack := NULL;
            ELSE
                l_redo_state := SUBSTR(l_session.REDO_STACK, l_last_pipe_pos + 1);
                l_new_redo_stack := SUBSTR(l_session.REDO_STACK, 1, l_last_pipe_pos - 1);
            END IF;
            
            UPDATE GAME_SESSIONS
            SET BOARD_STATE = l_redo_state, MOVE_COUNT = l_session.MOVE_COUNT + 1, REDO_STACK = l_new_redo_stack
            WHERE SESSION_ID = p_session_id;

            INSERT INTO MOVE_HISTORY (SESSION_ID, BOARD_STATE, MOVE_ORDER)
            VALUES (p_session_id, l_redo_state, l_session.MOVE_COUNT + 1);
            COMMIT;
        END IF;
        RETURN get_game_state_json(p_session_id);
    END redo_move;

    PROCEDURE abandon_game(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) AS
        l_session GAME_SESSIONS%ROWTYPE;
        l_duration NUMBER;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;
        l_duration := ROUND((CAST(CURRENT_TIMESTAMP AS DATE) - CAST(l_session.START_TIME AS DATE)) * 86400);
        INSERT INTO GAME_ARCHIVE (USER_ID, BOARD_SIZE, MOVES_MADE, DURATION_SECONDS, RESULT, GAME_MODE)
        VALUES (l_session.USER_ID, l_session.BOARD_SIZE, l_session.MOVE_COUNT, l_duration, 'ABANDONED', l_session.GAME_MODE);
        DELETE FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
    END abandon_game;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ БЛОКА ПОДСКАЗОК И РЕЙТИНГОВ
    ----------------------------------------------------------------------------

    FUNCTION get_leaderboards(p_filter_size IN NUMBER, p_filter_difficulty IN NUMBER) RETURN CLOB AS
        l_json CLOB;
        l_query VARCHAR2(4000);
    BEGIN
        l_query := '
            SELECT JSON_ARRAYAGG(
                JSON_OBJECT(''user'' VALUE u.USERNAME, ''total_stars'' VALUE SUM(a.STARS_EARNED))
                ORDER BY SUM(a.STARS_EARNED) DESC
                RETURNING CLOB
            )
            FROM GAME_ARCHIVE a
            JOIN USERS u ON a.USER_ID = u.USER_ID
            WHERE u.USERNAME != ''player1'' ';

        IF p_filter_size > 0 THEN
            l_query := l_query || ' AND a.BOARD_SIZE = :1';
        END IF;
        
        IF p_filter_difficulty > 0 THEN
            IF INSTR(l_query, ':1') > 0 THEN
                l_query := l_query || ' AND a.DIFFICULTY_LEVEL = :2';
            ELSE
                l_query := l_query || ' AND a.DIFFICULTY_LEVEL = :1';
            END IF;
        END IF;

        l_query := l_query || ' GROUP BY u.USERNAME';

        IF p_filter_size > 0 AND p_filter_difficulty > 0 THEN
            EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_size, p_filter_difficulty;
        ELSIF p_filter_size > 0 THEN
            EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_size;
        ELSIF p_filter_difficulty > 0 THEN
            EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_difficulty;
        ELSE
            EXECUTE IMMEDIATE l_query INTO l_json;
        END IF;
        
        RETURN JSON_OBJECT('leaderboard' VALUE JSON_QUERY(NVL(l_json, '[]'), '$'));
    END get_leaderboards;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ СОЛВЕРА (ранее GAME_SOLVER_PKG)
    ----------------------------------------------------------------------------
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
        p_path      IN OUT NOCOPY GAME_MANAGER_PKG.t_path,
        p_g_cost    IN NUMBER,
        p_threshold IN NUMBER,
        o_solution  OUT NOCOPY GAME_MANAGER_PKG.t_path
    ) RETURN NUMBER IS
        l_current_node  GAME_MANAGER_PKG.t_node;
        l_f_cost        NUMBER;
        l_min_f         NUMBER := 999999;
        l_empty_idx     PLS_INTEGER;
    BEGIN
        l_current_node := p_path(p_path.COUNT);
        l_f_cost := p_g_cost + l_current_node.h_cost;

        IF l_f_cost > p_threshold THEN
            RETURN l_f_cost;
        END IF;

        IF l_current_node.h_cost = 0 THEN
            o_solution := p_path;
            RETURN -1;
        END IF;

        FOR i IN 1 .. l_current_node.board_state.COUNT LOOP
            IF l_current_node.board_state(i) = 0 THEN
                l_empty_idx := i;
                EXIT;
            END IF;
        END LOOP;

        DECLARE
            l_possible_moves GAME_MANAGER_PKG.t_board;
            k PLS_INTEGER := 1;
        BEGIN
            IF l_empty_idx - g_board_size > 0 THEN l_possible_moves(k) := l_empty_idx - g_board_size; k := k + 1; END IF;
            IF l_empty_idx + g_board_size <= g_board_size*g_board_size THEN l_possible_moves(k) := l_empty_idx + g_board_size; k := k + 1; END IF;
            IF MOD(l_empty_idx - 1, g_board_size) > 0 THEN l_possible_moves(k) := l_empty_idx - 1; k := k + 1; END IF;
            IF MOD(l_empty_idx - 1, g_board_size) < g_board_size - 1 THEN l_possible_moves(k) := l_empty_idx + 1; END IF;

            FOR i IN 1 .. l_possible_moves.COUNT LOOP
                DECLARE
                    l_next_board GAME_MANAGER_PKG.t_board;
                    l_next_node  GAME_MANAGER_PKG.t_node;
                    l_temp       NUMBER;
                    l_res        NUMBER;
                BEGIN
                    l_next_board := l_current_node.board_state;
                    l_temp := l_next_board(l_possible_moves(i));
                    l_next_board(l_possible_moves(i)) := 0;
                    l_next_board(l_empty_idx) := l_temp;

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
        l_path          GAME_MANAGER_PKG.t_path;
        l_solution      GAME_MANAGER_PKG.t_path;
        l_initial_node  GAME_MANAGER_PKG.t_node;
        l_threshold     NUMBER;
        l_result        NUMBER;
        l_start_time    NUMBER;
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

    -- Реализация get_hint после того как солвер определен
    FUNCTION get_hint(p_session_id IN GAME_SESSIONS.SESSION_ID%TYPE) RETURN VARCHAR2 IS
        l_session GAME_SESSIONS%ROWTYPE;
        l_tile_to_move NUMBER;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;
        l_tile_to_move := get_next_best_move(
            p_board_state        => l_session.BOARD_STATE,
            p_target_board_state => l_session.TARGET_STATE,
            p_board_size_param   => l_session.BOARD_SIZE
        );
        RETURN JSON_OBJECT('hint' VALUE l_tile_to_move);
    END get_hint;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ ПРИВАТНЫХ УТИЛИТ
    ----------------------------------------------------------------------------
    FUNCTION get_game_state_json(p_session_id IN NUMBER) RETURN CLOB IS
        l_json_clob CLOB;
        l_session GAME_SESSIONS%ROWTYPE;
    BEGIN
        SELECT * INTO l_session FROM GAME_SESSIONS WHERE SESSION_ID = p_session_id;

        SELECT JSON_OBJECT(
            'sessionId' VALUE l_session.SESSION_ID,
            'boardSize' VALUE l_session.BOARD_SIZE,
            'boardState' VALUE JSON_QUERY('[' || l_session.BOARD_STATE || ']', '$'),
            'moves' VALUE l_session.MOVE_COUNT,
            'startTime' VALUE TO_CHAR(l_session.START_TIME, 'YYYY-MM-DD"T"HH24:MI:SS'),
            'status' VALUE l_session.STATUS,
            'imageUrl' VALUE l_session.IMAGE_URL,
            'stars' VALUE null
        ) INTO l_json_clob
        FROM dual;
        
        RETURN l_json_clob;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN '{"status":"error", "message":"Session not found"}';
    END get_game_state_json;

    FUNCTION calculate_heuristic(p_board GAME_MANAGER_PKG.t_board) RETURN NUMBER IS
        l_heuristic NUMBER := 0;
        l_current_pos PLS_INTEGER;
        l_target_pos PLS_INTEGER;
        l_current_row PLS_INTEGER;
        l_current_col PLS_INTEGER;
        l_target_row PLS_INTEGER;
        l_target_col PLS_INTEGER;
    BEGIN
        FOR i IN 1 .. p_board.COUNT LOOP
            IF p_board(i) != 0 THEN
                l_current_pos := i;
                l_target_pos  := g_target_positions(p_board(i));
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
        l_string         VARCHAR2(32767) := p_state || ',';
        l_comma_index    PLS_INTEGER;
        l_start_index    PLS_INTEGER := 1;
        l_result_table   GAME_MANAGER_PKG.t_board;
        i                PLS_INTEGER := 1;
    BEGIN
        LOOP
            l_comma_index := INSTR(l_string, ',', l_start_index);
            EXIT WHEN l_comma_index = 0;
            l_result_table(i) := TO_NUMBER(SUBSTR(l_string, l_start_index, l_comma_index - l_start_index));
            l_start_index := l_comma_index + 1;
            i := i + 1;
        END LOOP;
        RETURN l_result_table;
    END state_to_table;

    FUNCTION table_to_state(p_table IN GAME_MANAGER_PKG.t_board) RETURN VARCHAR2 IS
        l_state VARCHAR2(32767);
    BEGIN
        IF p_table.COUNT = 0 THEN RETURN NULL; END IF;
        FOR i IN p_table.FIRST..p_table.LAST LOOP
            l_state := l_state || p_table(i) || ',';
        END LOOP;
        RETURN RTRIM(l_state, ',');
    END table_to_state;

END GAME_MANAGER_PKG;
/