-- =============================================================================
-- Файл: game_logic_packed.sql
-- Версия: 4.0 (Адаптировано под новую схему БД)
-- Описание: Полный пакет для управления игровой логикой "Пятнашек".
-- =============================================================================

-- 1. СПЕЦИФИКАЦИЯ ПАКЕТА
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
    -- API: БЛОК АВТОРИЗАЦИИ
    ----------------------------------------------------------------------------
    FUNCTION register_user(
        p_username      IN VARCHAR2,
        p_password_hash IN VARCHAR2
    ) RETURN NUMBER;

    FUNCTION login_user(
        p_username      IN VARCHAR2,
        p_password_hash IN VARCHAR2
    ) RETURN NUMBER;

    ----------------------------------------------------------------------------
    -- API: БЛОК УПРАВЛЕНИЯ ИГРОЙ И СЕССИЯМИ
    ----------------------------------------------------------------------------
    PROCEDURE cleanup_expired_games;

    FUNCTION check_active_session(
        p_user_id IN USERS.USER_ID%TYPE
    ) RETURN CLOB;

    FUNCTION start_new_game(
        p_user_id           IN USERS.USER_ID%TYPE,
        p_board_size        IN NUMBER,
        p_shuffle_moves     IN NUMBER,
        p_game_mode         IN VARCHAR2,
        p_image_id          IN NUMBER,
        p_is_daily_challenge IN BOOLEAN,
        p_force_new         IN BOOLEAN,
        p_replay_game_id    IN GAMES.GAME_ID%TYPE DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION process_move(
        p_session_id IN GAMES.GAME_ID%TYPE,
        p_tile_value IN NUMBER
    ) RETURN CLOB;

    FUNCTION undo_move(
        p_session_id IN GAMES.GAME_ID%TYPE
    ) RETURN CLOB;

    FUNCTION redo_move(
        p_session_id IN GAMES.GAME_ID%TYPE
    ) RETURN CLOB;

    PROCEDURE abandon_game(
        p_session_id IN GAMES.GAME_ID%TYPE
    );
    
    PROCEDURE timeout_game(
        p_session_id IN GAMES.GAME_ID%TYPE
    );

    FUNCTION restart_game(
        p_session_id IN GAMES.GAME_ID%TYPE
    ) RETURN CLOB;

    ----------------------------------------------------------------------------
    -- API: БЛОК ПОДСКАЗОК, РЕЙТИНГОВ И ИЗОБРАЖЕНИЙ
    ----------------------------------------------------------------------------
    FUNCTION get_hint(
        p_session_id IN GAMES.GAME_ID%TYPE
    ) RETURN VARCHAR2;

    FUNCTION get_leaderboards(
        p_filter_size       IN NUMBER,
        p_filter_difficulty IN NUMBER
    ) RETURN CLOB;

    FUNCTION get_game_history(
        p_user_id IN USERS.USER_ID%TYPE
    ) RETURN CLOB;
    
    FUNCTION save_user_image(
        p_user_id    IN USERS.USER_ID%TYPE,
        p_mime_type  IN VARCHAR2,
        p_image_data IN BLOB,
        p_image_hash IN VARCHAR2
    ) RETURN NUMBER;

    FUNCTION get_user_images(
        p_user_id IN USERS.USER_ID%TYPE
    ) RETURN CLOB;
    
    PROCEDURE get_user_image_data(
        p_image_id   IN NUMBER,
        o_mime_type  OUT VARCHAR2,
        o_image_data OUT BLOB
    );

    FUNCTION get_default_images RETURN CLOB;
    
    PROCEDURE get_default_image_data(
        p_image_id   IN NUMBER,
        o_mime_type  OUT VARCHAR2,
        o_image_data OUT BLOB
    );
    
    PROCEDURE delete_user_image(
        p_user_id  IN USERS.USER_ID%TYPE,
        p_image_id IN USER_IMAGES.IMAGE_ID%TYPE
    );
    
    ----------------------------------------------------------------------------
    -- API: БЛОК ДЛЯ ПЛАНИРОВЩИКА
    ----------------------------------------------------------------------------
    PROCEDURE create_daily_challenge;
    
    FUNCTION get_user_stats(
        p_user_id IN USERS.USER_ID%TYPE
    ) RETURN CLOB;

END GAME_MANAGER_PKG;
/

-- 2. ТЕЛО ПАКЕТА
CREATE OR REPLACE PACKAGE BODY GAME_MANAGER_PKG AS
    ----------------------------------------------------------------------------
    -- ПРИВАТНЫЕ УТИЛИТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
    ----------------------------------------------------------------------------
    g_target_positions GAME_MANAGER_PKG.t_board;
    g_board_size       NUMBER;
    
    FUNCTION state_to_table(p_state IN VARCHAR2) RETURN GAME_MANAGER_PKG.t_board;
    FUNCTION table_to_state(p_table IN GAME_MANAGER_PKG.t_board) RETURN VARCHAR2;
    FUNCTION get_game_state_json(p_game_id IN NUMBER) RETURN CLOB;
    FUNCTION calculate_heuristic(p_board GAME_MANAGER_PKG.t_board) RETURN NUMBER;
    PROCEDURE init_target_positions(p_target_board GAME_MANAGER_PKG.t_board, p_size NUMBER);
    FUNCTION is_state_in_path(p_path GAME_MANAGER_PKG.t_path, p_board GAME_MANAGER_PKG.t_board) RETURN BOOLEAN;
    FUNCTION search(p_path IN OUT NOCOPY GAME_MANAGER_PKG.t_path, p_g_cost IN NUMBER, p_threshold IN NUMBER, o_solution OUT NOCOPY GAME_MANAGER_PKG.t_path) RETURN NUMBER;
    FUNCTION get_next_best_move(p_board_state IN VARCHAR2, p_target_board_state IN VARCHAR2, p_board_size_param IN NUMBER) RETURN NUMBER;
    
    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ: БЛОК АВТОРИЗАЦИИ
    ----------------------------------------------------------------------------
    FUNCTION register_user(
        p_username      IN VARCHAR2,
        p_password_hash IN VARCHAR2
    ) RETURN NUMBER
    AS
        l_user_id USERS.USER_ID%TYPE;
        l_count   NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO l_count
        FROM USERS
        WHERE USERNAME = p_username;

        IF l_count > 0 THEN
            RETURN -1;
        END IF;

        INSERT INTO USERS (USER_ID, USERNAME, PASSWORD_HASH)
        VALUES (USERS_SEQ.NEXTVAL, p_username, p_password_hash)
        RETURNING USER_ID INTO l_user_id;

        COMMIT;
        RETURN l_user_id;
    END register_user;

    FUNCTION login_user(
        p_username      IN VARCHAR2,
        p_password_hash IN VARCHAR2
    ) RETURN NUMBER
    AS
        l_user_id USERS.USER_ID%TYPE;
    BEGIN
        SELECT USER_ID
        INTO l_user_id
        FROM USERS
        WHERE USERNAME = p_username AND PASSWORD_HASH = p_password_hash;
        RETURN l_user_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
    END login_user;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ: БЛОК УПРАВЛЕНИЯ ИГРОЙ
    ----------------------------------------------------------------------------
    
    PROCEDURE cleanup_expired_games AS
    BEGIN
        FOR rec IN (
            SELECT 
                GAME_ID,
                START_TIME + (CEIL(10 * (BOARD_SIZE / 4)) / (24 * 60)) AS EXPIRATION_TIME
            FROM GAMES
            WHERE STATUS = 'ACTIVE'
        ) LOOP
            IF rec.EXPIRATION_TIME < SYSDATE THEN
                -- --- ИСПРАВЛЕНО: Удалена строка с CURRENT_MOVE_ORDER = null ---
                UPDATE GAMES
                SET STATUS = 'ABANDONED',
                    COMPLETED_AT = rec.EXPIRATION_TIME,
                    CURRENT_MOVE_ORDER = NULL
                WHERE GAME_ID = rec.GAME_ID;

                DELETE FROM MOVE_HISTORY WHERE GAME_ID = rec.GAME_ID;
            END IF;
        END LOOP;
        COMMIT;
    END cleanup_expired_games;

    FUNCTION check_active_session(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB 
    AS
        l_game_id   GAMES.GAME_ID%TYPE;
        l_json_clob CLOB;
    BEGIN
        cleanup_expired_games; 
        
        SELECT GAME_ID 
        INTO l_game_id 
        FROM GAMES 
        WHERE USER_ID = p_user_id AND STATUS = 'ACTIVE';

        l_json_clob := get_game_state_json(l_game_id);
        l_json_clob := SUBSTR(l_json_clob, 1, LENGTH(l_json_clob) - 1) || ',"active_session_found":true}';
        RETURN l_json_clob;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN '{"active_session_found":false}';
    END check_active_session;

    FUNCTION start_new_game(
        p_user_id           IN USERS.USER_ID%TYPE,
        p_board_size        IN NUMBER,
        p_shuffle_moves     IN NUMBER,
        p_game_mode         IN VARCHAR2,
        p_image_id          IN NUMBER,
        p_is_daily_challenge IN BOOLEAN,
        p_force_new         IN BOOLEAN,
        p_replay_game_id    IN GAMES.GAME_ID%TYPE DEFAULT NULL
    ) RETURN CLOB
    AS
        l_game_id             GAMES.GAME_ID%TYPE;
        l_start_state         VARCHAR2(1000);
        l_size                NUMBER := p_board_size;
        l_shuffles            NUMBER := p_shuffle_moves;
        l_challenge_id        GAMES.CHALLENGE_ID%TYPE := NULL;
        l_optimal_moves       GAMES.OPTIMAL_MOVES%TYPE;
        l_image_id_to_use     GAMES.IMAGE_ID%TYPE := p_image_id;
        l_game_mode_to_use    GAMES.GAME_MODE%TYPE := p_game_mode;
    BEGIN
        IF NOT p_force_new AND p_replay_game_id IS NULL THEN
            DECLARE 
                l_active_session_json CLOB := check_active_session(p_user_id);
            BEGIN
                IF INSTR(l_active_session_json, '"active_session_found":true') > 0 THEN
                    RETURN l_active_session_json;
                END IF;
            END;
        END IF;
        
        DECLARE
            l_old_game_id GAMES.GAME_ID%TYPE;
        BEGIN
            SELECT GAME_ID INTO l_old_game_id
            FROM GAMES
            WHERE USER_ID = p_user_id AND STATUS = 'ACTIVE'
            FETCH FIRST 1 ROWS ONLY;

            IF l_old_game_id IS NOT NULL THEN
                DELETE FROM MOVE_HISTORY WHERE GAME_ID = l_old_game_id;
                DELETE FROM GAMES WHERE GAME_ID = l_old_game_id;
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                NULL;
        END;
        
        IF p_replay_game_id IS NOT NULL THEN
            DECLARE
                l_original_game GAMES%ROWTYPE;
            BEGIN
                SELECT * INTO l_original_game FROM GAMES WHERE GAME_ID = p_replay_game_id;
                
                -- --- ИСПРАВЛЕНО: Используется правильное имя поля INITIAL_BOARD_STATE ---
                l_start_state       := l_original_game.INITIAL_BOARD_STATE; 
                l_size              := l_original_game.BOARD_SIZE;
                l_shuffles          := l_original_game.SHUFFLE_MOVES;
                l_game_mode_to_use  := l_original_game.GAME_MODE;
                l_image_id_to_use   := l_original_game.IMAGE_ID;
                l_challenge_id      := l_original_game.CHALLENGE_ID;
                l_optimal_moves     := l_original_game.OPTIMAL_MOVES;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RETURN '{"error":"Original game for replay not found"}';
            END;
        ELSIF p_is_daily_challenge THEN
            DECLARE 
                l_daily DAILY_CHALLENGES%ROWTYPE; 
            BEGIN 
                SELECT * INTO l_daily FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = TRUNC(SYSDATE);
                l_challenge_id    := l_daily.CHALLENGE_ID;
                l_size            := l_daily.BOARD_SIZE;
                l_shuffles        := l_daily.SHUFFLE_MOVES;
                l_start_state     := l_daily.BOARD_STATE;
                l_optimal_moves   := l_daily.OPTIMAL_MOVES;
                l_image_id_to_use := l_daily.IMAGE_ID;
                IF l_daily.IMAGE_ID IS NOT NULL THEN
                    l_game_mode_to_use := 'IMAGE';
                ELSE
                    l_game_mode_to_use := 'INTS';
                END IF;
            EXCEPTION 
                WHEN NO_DATA_FOUND THEN 
                    RETURN '{"error":"Daily challenge not found for today"}'; 
            END;
        ELSE
            DECLARE 
                l_target_state VARCHAR2(1000); 
            BEGIN 
                l_target_state := ''; 
                FOR i IN 1..(l_size*l_size - 1) LOOP 
                    l_target_state := l_target_state || i || ','; 
                END LOOP; 
                l_target_state := l_target_state || '0'; 
                
                LOOP 
                    DECLARE 
                        l_board GAME_MANAGER_PKG.t_board := state_to_table(l_target_state); 
                        l_empty_idx PLS_INTEGER := l_size*l_size; 
                    BEGIN 
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
                    END; 
                    EXIT WHEN l_start_state != l_target_state; 
                END LOOP; 
                
                DECLARE 
                    l_path GAME_MANAGER_PKG.t_path; 
                    l_solution GAME_MANAGER_PKG.t_path; 
                    l_initial_node GAME_MANAGER_PKG.t_node; 
                    l_threshold NUMBER; 
                    l_result NUMBER; 
                BEGIN 
                    init_target_positions(state_to_table(l_target_state), l_size); 
                    l_initial_node.board_state := state_to_table(l_start_state); 
                    l_initial_node.g_cost := 0; 
                    l_initial_node.h_cost := calculate_heuristic(l_initial_node.board_state); 
                    l_path(1) := l_initial_node; 
                    l_threshold := l_initial_node.h_cost; 
                    
                    LOOP 
                        l_result := search(l_path, 0, l_threshold, l_solution); 
                        IF l_result = -1 THEN EXIT; END IF; 
                        l_threshold := l_result; 
                        IF l_threshold > 80 THEN l_solution.DELETE; EXIT; END IF; 
                    END LOOP; 
                    
                    IF l_solution.COUNT > 0 THEN
                        l_optimal_moves := l_solution.COUNT - 1; 
                    ELSE
                        l_optimal_moves := 0;
                    END IF;
                END;
            END;
        END IF;
        
        INSERT INTO GAMES (
            GAME_ID, USER_ID, STATUS, BOARD_SIZE, SHUFFLE_MOVES, GAME_MODE, MOVE_COUNT,
            IMAGE_ID, CHALLENGE_ID, START_TIME, DURATION_SECONDS, STARS_EARNED,
            OPTIMAL_MOVES, CURRENT_MOVE_ORDER, INITIAL_BOARD_STATE
        ) VALUES (
            GAMES_SEQ.NEXTVAL, p_user_id, 'ACTIVE', l_size, l_shuffles, l_game_mode_to_use, 0,
            l_image_id_to_use, l_challenge_id, SYSDATE, 0, 0,
            l_optimal_moves, 0, l_start_state
        )
        RETURNING GAME_ID INTO l_game_id;
        
        INSERT INTO MOVE_HISTORY (MOVE_ID, GAME_ID, MOVE_ORDER, BOARD_STATE)
        VALUES (MOVE_HISTORY_SEQ.NEXTVAL, l_game_id, 0, l_start_state);
    
        COMMIT;
        RETURN get_game_state_json(l_game_id);
    END start_new_game;
    
    PROCEDURE abandon_game(p_session_id IN GAMES.GAME_ID%TYPE) 
    AS
        l_duration   NUMBER;
        l_start_time DATE;
    BEGIN
        SELECT START_TIME INTO l_start_time FROM GAMES WHERE GAME_ID = p_session_id;
        l_duration := ROUND((SYSDATE - l_start_time) * 86400);

        UPDATE GAMES
        SET STATUS = 'ABANDONED',
            COMPLETED_AT = SYSDATE,
            DURATION_SECONDS = l_duration,
            CURRENT_MOVE_ORDER = NULL
        WHERE GAME_ID = p_session_id;

        DELETE FROM MOVE_HISTORY WHERE GAME_ID = p_session_id;

        COMMIT;
    END abandon_game;
    
    PROCEDURE timeout_game(p_session_id IN GAMES.GAME_ID%TYPE)
    AS
        l_game GAMES%ROWTYPE;
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id;

        UPDATE GAMES
        SET STATUS = 'TIMEOUT',
            COMPLETED_AT = l_game.START_TIME + (l_game.DURATION_SECONDS / 86400),
            STARS_EARNED = 0,
            CURRENT_MOVE_ORDER = NULL
        WHERE GAME_ID = p_session_id;

        DELETE FROM MOVE_HISTORY WHERE GAME_ID = p_session_id;
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
    END timeout_game;

    FUNCTION restart_game(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB
    AS
        l_game GAMES%ROWTYPE;
        l_initial_state VARCHAR2(1000);
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id;
        l_initial_state := l_game.INITIAL_BOARD_STATE;
        
        DELETE FROM MOVE_HISTORY WHERE GAME_ID = p_session_id;
        
        INSERT INTO MOVE_HISTORY (MOVE_ID, GAME_ID, MOVE_ORDER, BOARD_STATE)
        VALUES (MOVE_HISTORY_SEQ.NEXTVAL, p_session_id, 0, l_initial_state);
        
        UPDATE GAMES
        SET 
            MOVE_COUNT = 0,
            CURRENT_MOVE_ORDER = 0,
            START_TIME = SYSDATE,
            DURATION_SECONDS = 0,
            STATUS = 'ACTIVE'
        WHERE GAME_ID = p_session_id;
        
        COMMIT;
        
        -- Возвращаем обновленное состояние игры
        RETURN get_game_state_json(p_session_id);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'Game session not found');
    END restart_game;

    FUNCTION process_move(
        p_session_id IN GAMES.GAME_ID%TYPE, 
        p_tile_value IN NUMBER
    ) RETURN CLOB 
    AS 
        l_game              GAMES%ROWTYPE; 
        l_board             GAME_MANAGER_PKG.t_board; 
        l_current_state     MOVE_HISTORY.BOARD_STATE%TYPE; 
        l_empty_idx         PLS_INTEGER; 
        l_tile_idx          PLS_INTEGER; 
        l_is_adjacent       BOOLEAN := FALSE; 
        l_new_board_state   VARCHAR2(1000); 
        l_stars             NUMBER := 0; 
        l_duration          NUMBER; 
        l_target_state      VARCHAR2(1000); 
    BEGIN 
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id AND STATUS = 'ACTIVE'; 
        
        SELECT BOARD_STATE INTO l_current_state 
        FROM MOVE_HISTORY 
        WHERE GAME_ID = p_session_id AND MOVE_ORDER = l_game.CURRENT_MOVE_ORDER; 
        
        l_board := state_to_table(l_current_state); 
        
        FOR i IN l_board.FIRST..l_board.LAST LOOP 
            IF l_board(i) = 0 THEN l_empty_idx := i; END IF; 
            IF l_board(i) = p_tile_value THEN l_tile_idx := i; END IF; 
        END LOOP; 
        
        IF (ABS(l_tile_idx - l_empty_idx) = 1 AND TRUNC((l_tile_idx-1)/l_game.BOARD_SIZE) = TRUNC((l_empty_idx-1)/l_game.BOARD_SIZE)) 
            OR (ABS(l_tile_idx - l_empty_idx) = l_game.BOARD_SIZE) THEN 
            l_is_adjacent := TRUE; 
        END IF; 
        
        IF l_is_adjacent THEN 
            l_board(l_empty_idx) := l_board(l_tile_idx); 
            l_board(l_tile_idx) := 0; 
            l_new_board_state := table_to_state(l_board); 
            
            l_target_state := ''; 
            FOR i IN 1..(l_game.BOARD_SIZE * l_game.BOARD_SIZE - 1) LOOP 
                l_target_state := l_target_state || i || ','; 
            END LOOP; 
            l_target_state := l_target_state || '0'; 
            
            IF l_new_board_state = l_target_state THEN 
                l_duration := ROUND((SYSDATE - l_game.START_TIME) * 86400); 
                
                IF l_game.OPTIMAL_MOVES > 0 THEN 
                    IF (l_game.MOVE_COUNT + 1) <= l_game.OPTIMAL_MOVES THEN l_stars := 3; 
                    ELSIF (l_game.MOVE_COUNT + 1) <= l_game.OPTIMAL_MOVES * 1.2 THEN l_stars := 2; 
                    ELSE l_stars := 1; 
                    END IF; 
                ELSE 
                    l_stars := 1; 
                END IF; 
                
                UPDATE GAMES 
                SET STATUS = 'SOLVED', 
                    MOVE_COUNT = l_game.MOVE_COUNT + 1, 
                    COMPLETED_AT = SYSDATE, 
                    DURATION_SECONDS = l_duration, 
                    STARS_EARNED = l_stars,
                    CURRENT_MOVE_ORDER = null
                WHERE GAME_ID = p_session_id; 
                
                DELETE FROM MOVE_HISTORY WHERE GAME_ID = p_session_id;

                COMMIT;

                DECLARE
                    l_final_json CLOB;
                    l_image_url VARCHAR2(256);
                BEGIN
                    IF l_game.IMAGE_ID IS NOT NULL THEN
                        l_image_url := '/api/image/' || l_game.IMAGE_ID;
                    END IF;

                    SELECT
                        JSON_OBJECT(
                            'sessionId'  VALUE l_game.GAME_ID,
                            'boardSize'  VALUE l_game.BOARD_SIZE,
                            'boardState' VALUE JSON_QUERY('[' || l_new_board_state || ']', '$'),
                            'moves'      VALUE l_game.MOVE_COUNT + 1,
                            'startTime'  VALUE TO_CHAR(l_game.START_TIME, 'YYYY-MM-DD"T"HH24:MI:SS'),
                            'status'     VALUE 'SOLVED',
                            'imageUrl'   VALUE l_image_url,
                            'stars'      VALUE l_stars,
                            'gameMode'   VALUE l_game.GAME_MODE
                        )
                    INTO l_final_json
                    FROM dual;
                    RETURN l_final_json;
                END;
                
            ELSE 
                DELETE FROM MOVE_HISTORY 
                WHERE GAME_ID = p_session_id AND MOVE_ORDER > l_game.CURRENT_MOVE_ORDER; 
                
                INSERT INTO MOVE_HISTORY (MOVE_ID, GAME_ID, MOVE_ORDER, BOARD_STATE) 
                VALUES (MOVE_HISTORY_SEQ.NEXTVAL, p_session_id, l_game.CURRENT_MOVE_ORDER + 1, l_new_board_state); 
                
                UPDATE GAMES 
                SET MOVE_COUNT = l_game.MOVE_COUNT + 1, 
                    CURRENT_MOVE_ORDER = l_game.CURRENT_MOVE_ORDER + 1
                WHERE GAME_ID = p_session_id; 
            END IF; 
            COMMIT; 
        END IF; 
        RETURN get_game_state_json(p_session_id); 
    END process_move;

    FUNCTION undo_move(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB 
    AS 
        l_game GAMES%ROWTYPE; 
    BEGIN 
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id AND STATUS = 'ACTIVE'; 
        
        IF l_game.CURRENT_MOVE_ORDER > 0 THEN 
            UPDATE GAMES 
            SET CURRENT_MOVE_ORDER = l_game.CURRENT_MOVE_ORDER - 1, 
                MOVE_COUNT = l_game.MOVE_COUNT - 1
            WHERE GAME_ID = p_session_id; 
            COMMIT; 
        END IF; 
        
        RETURN get_game_state_json(p_session_id); 
    END undo_move;

    FUNCTION redo_move(p_session_id IN GAMES.GAME_ID%TYPE) RETURN CLOB 
    AS 
        l_max_move_order     NUMBER; 
        l_game               GAMES%ROWTYPE;
    BEGIN 
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id AND STATUS = 'ACTIVE'; 
        
        SELECT MAX(MOVE_ORDER) INTO l_max_move_order 
        FROM MOVE_HISTORY WHERE GAME_ID = p_session_id; 
        
        IF l_game.CURRENT_MOVE_ORDER < l_max_move_order THEN 
            UPDATE GAMES 
            SET CURRENT_MOVE_ORDER = l_game.CURRENT_MOVE_ORDER + 1, 
                MOVE_COUNT = l_game.MOVE_COUNT + 1
            WHERE GAME_ID = p_session_id; 
            COMMIT; 
        END IF; 
        
        RETURN get_game_state_json(p_session_id); 
    END redo_move;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ: БЛОК ПОДСКАЗОК, РЕЙТИНГОВ И ИЗОБРАЖЕНИЙ
    ----------------------------------------------------------------------------
    FUNCTION get_leaderboards(
        p_filter_size       IN NUMBER,
        p_filter_difficulty IN NUMBER
    ) RETURN CLOB
    AS
        l_json  CLOB;
        l_query VARCHAR2(4000);
    BEGIN
        l_query := '
            SELECT JSON_ARRAYAGG(
                JSON_OBJECT(
                    ''user'' VALUE u.USERNAME,
                    ''total_stars'' VALUE NVL(SUM(g.STARS_EARNED), 0),
                    ''solved_games'' VALUE COUNT(CASE WHEN g.STATUS = ''SOLVED'' THEN 1 END),
                    ''unfinished_games'' VALUE COUNT(CASE WHEN g.STATUS IN (''ABANDONED'', ''TIMEOUT'') THEN 1 END)
                ) ORDER BY NVL(SUM(g.STARS_EARNED), 0) DESC, COUNT(CASE WHEN g.STATUS = ''SOLVED'' THEN 1 END) DESC
                RETURNING CLOB
            )
            FROM USERS u
            LEFT JOIN GAMES g ON u.USER_ID = g.USER_ID
            WHERE 1=1 ';

        IF p_filter_size > 0 THEN
            l_query := l_query || ' AND g.BOARD_SIZE = :1';
        END IF;

        IF p_filter_difficulty > 0 THEN
            l_query := l_query || ' AND g.SHUFFLE_MOVES = :2';
        END IF;

        l_query := l_query || ' GROUP BY u.USERNAME';

        IF p_filter_size > 0 AND p_filter_difficulty > 0 THEN
            EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_size, p_filter_difficulty;
        ELSIF p_filter_size > 0 THEN
            l_query := REPLACE(l_query, ':2', 'NULL');
            EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_size;
        ELSIF p_filter_difficulty > 0 THEN
            l_query := REPLACE(l_query, ':1', 'NULL');
            EXECUTE IMMEDIATE l_query INTO l_json USING p_filter_difficulty;
        ELSE
            l_query := REPLACE(REPLACE(l_query, ':1', 'NULL'), ':2', 'NULL');
            EXECUTE IMMEDIATE l_query INTO l_json;
        END IF;

        RETURN JSON_OBJECT('leaderboard' VALUE JSON_QUERY(NVL(l_json, '[]'), '$'));
    END get_leaderboards;
    
    FUNCTION get_game_history(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB
    AS
        l_json CLOB;
    BEGIN
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'gameId' VALUE g.GAME_ID,
                'date'   VALUE TO_CHAR(g.START_TIME, 'DD.MM.YYYY HH24:MI'),
                'size'   VALUE g.BOARD_SIZE,
                'moves'  VALUE g.MOVE_COUNT,
                'time'   VALUE g.DURATION_SECONDS,
                'status' VALUE g.STATUS,
                'stars'  VALUE g.STARS_EARNED
            ) ORDER BY g.START_TIME DESC
        )
        INTO l_json
        FROM GAMES g
        WHERE g.USER_ID = p_user_id AND g.STATUS IN ('SOLVED', 'ABANDONED', 'TIMEOUT');

        RETURN NVL(l_json, '[]');
    END get_game_history;

    FUNCTION save_user_image(
        p_user_id    IN USERS.USER_ID%TYPE,
        p_mime_type  IN VARCHAR2,
        p_image_data IN BLOB,
        p_image_hash IN VARCHAR2
    ) RETURN NUMBER 
    AS 
        l_count       NUMBER; 
        l_image_limit CONSTANT NUMBER := 7; 
    BEGIN 
        SELECT COUNT(*) INTO l_count FROM USER_IMAGES WHERE USER_ID = p_user_id; 
        IF l_count >= l_image_limit THEN 
            RETURN 2; 
        END IF; 
        
        SELECT COUNT(*) INTO l_count FROM USER_IMAGES WHERE USER_ID = p_user_id AND IMAGE_HASH = p_image_hash; 
        IF l_count > 0 THEN 
            RETURN 0; 
        END IF; 
        
        INSERT INTO USER_IMAGES (IMAGE_ID, USER_ID, MIME_TYPE, IMAGE_DATA, IMAGE_HASH, UPLOADED_AT) 
        VALUES (USER_IMAGES_SEQ.NEXTVAL, p_user_id, p_mime_type, p_image_data, p_image_hash, SYSDATE); 
        
        COMMIT; 
        RETURN 1; 
    EXCEPTION 
        WHEN DUP_VAL_ON_INDEX THEN 
            RETURN 0; 
    END save_user_image;

    FUNCTION get_user_images(p_user_id IN USERS.USER_ID%TYPE) RETURN CLOB 
    AS 
        l_json CLOB; 
    BEGIN 
        SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE IMAGE_ID) ORDER BY UPLOADED_AT DESC) 
        INTO l_json 
        FROM USER_IMAGES 
        WHERE USER_ID = p_user_id; 
        
        RETURN NVL(l_json, '[]'); 
    END get_user_images;

    PROCEDURE get_user_image_data(
        p_image_id   IN NUMBER,
        o_mime_type  OUT VARCHAR2,
        o_image_data OUT BLOB
    ) 
    AS 
    BEGIN 
        SELECT MIME_TYPE, IMAGE_DATA 
        INTO o_mime_type, o_image_data 
        FROM USER_IMAGES 
        WHERE IMAGE_ID = p_image_id; 
    END get_user_image_data;
    
    FUNCTION get_default_images RETURN CLOB 
    AS 
        l_json CLOB; 
    BEGIN 
        SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE IMAGE_ID, 'name' VALUE 'Default') ORDER BY IMAGE_ID) 
        INTO l_json 
        FROM USER_IMAGES 
        WHERE USER_ID IS NULL; 
        
        RETURN NVL(l_json, '[]'); 
    END get_default_images;
    
    PROCEDURE get_default_image_data(
        p_image_id   IN NUMBER,
        o_mime_type  OUT VARCHAR2,
        o_image_data OUT BLOB
    ) 
    AS 
    BEGIN 
        SELECT MIME_TYPE, IMAGE_DATA 
        INTO o_mime_type, o_image_data 
        FROM USER_IMAGES 
        WHERE IMAGE_ID = p_image_id AND USER_ID IS NULL; 
    END get_default_image_data;
    
    PROCEDURE delete_user_image(
        p_user_id  IN USERS.USER_ID%TYPE,
        p_image_id IN USER_IMAGES.IMAGE_ID%TYPE
    ) 
    AS 
    BEGIN 
        DELETE FROM USER_IMAGES 
        WHERE IMAGE_ID = p_image_id AND USER_ID = p_user_id; 
        COMMIT; 
    END delete_user_image;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ: СОЛВЕР И ПОДСКАЗКИ
    ----------------------------------------------------------------------------
    FUNCTION get_hint(p_session_id IN GAMES.GAME_ID%TYPE) RETURN VARCHAR2 
    AS 
        l_current_state VARCHAR2(1000); 
        l_game          GAMES%ROWTYPE; 
        l_target_state  VARCHAR2(1000); 
        l_tile_to_move  NUMBER; 
    BEGIN 
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_session_id; 
        
        SELECT BOARD_STATE INTO l_current_state 
        FROM MOVE_HISTORY 
        WHERE GAME_ID = p_session_id AND MOVE_ORDER = l_game.CURRENT_MOVE_ORDER; 
        
        l_target_state := ''; 
        FOR i IN 1..(l_game.BOARD_SIZE * l_game.BOARD_SIZE - 1) LOOP 
            l_target_state := l_target_state || i || ','; 
        END LOOP; 
        l_target_state := l_target_state || '0'; 
        
        l_tile_to_move := get_next_best_move( 
            p_board_state        => l_current_state, 
            p_target_board_state => l_target_state, 
            p_board_size_param   => l_game.BOARD_SIZE 
        ); 
        RETURN JSON_OBJECT('hint' VALUE l_tile_to_move); 
    END get_hint;
    
    PROCEDURE create_daily_challenge 
    AS 
        l_board_size     NUMBER; 
        l_shuffle_moves  NUMBER; 
        l_shuffled_board VARCHAR2(1000); 
        l_optimal_moves  NUMBER; 
        l_next_day       DATE := TRUNC(SYSDATE) + 1; 
        l_count          NUMBER; 
    BEGIN 
        SELECT COUNT(*) INTO l_count FROM DAILY_CHALLENGES WHERE CHALLENGE_DATE = l_next_day; 
        IF l_count > 0 THEN RETURN; END IF; 
        
        l_board_size := TRUNC(DBMS_RANDOM.VALUE(3, 5)); 
        IF l_board_size = 3 THEN l_shuffle_moves := TRUNC(DBMS_RANDOM.VALUE(20, 31)); 
        ELSE l_shuffle_moves := TRUNC(DBMS_RANDOM.VALUE(40, 71)); END IF; 
        
        DECLARE 
            l_target_state VARCHAR2(1000) := ''; 
        BEGIN 
            FOR i IN 1..(l_board_size * l_board_size - 1) LOOP 
                l_target_state := l_target_state || i || ','; 
            END LOOP; 
            l_target_state := l_target_state || '0'; 
            
            LOOP 
                DECLARE 
                    l_board GAME_MANAGER_PKG.t_board := state_to_table(l_target_state); 
                    l_empty_idx PLS_INTEGER := l_board_size * l_board_size; 
                BEGIN 
                    FOR i IN 1..l_shuffle_moves LOOP 
                        DECLARE 
                            l_possible_moves GAME_MANAGER_PKG.t_board; 
                            l_move_to_idx PLS_INTEGER; 
                            l_rand_move PLS_INTEGER; 
                            l_temp NUMBER; 
                            k PLS_INTEGER := 1; 
                        BEGIN 
                            IF MOD(l_empty_idx - 1, l_board_size) > 0 THEN l_possible_moves(k) := l_empty_idx - 1; k := k + 1; END IF; 
                            IF MOD(l_empty_idx - 1, l_board_size) < l_board_size - 1 THEN l_possible_moves(k) := l_empty_idx + 1; k := k + 1; END IF; 
                            IF l_empty_idx - l_board_size > 0 THEN l_possible_moves(k) := l_empty_idx - l_board_size; k := k + 1; END IF; 
                            IF l_empty_idx + l_board_size <= l_board_size*l_board_size THEN l_possible_moves(k) := l_empty_idx + l_board_size; END IF; 
                            l_rand_move := TRUNC(DBMS_RANDOM.VALUE(1, l_possible_moves.COUNT + 1)); 
                            l_move_to_idx := l_possible_moves(l_rand_move); 
                            l_temp := l_board(l_move_to_idx); 
                            l_board(l_move_to_idx) := l_board(l_empty_idx); 
                            l_board(l_empty_idx) := l_temp; 
                            l_empty_idx := l_move_to_idx; 
                        END; 
                    END LOOP; 
                    l_shuffled_board := table_to_state(l_board); 
                END; 
                EXIT WHEN l_shuffled_board != l_target_state; 
            END LOOP; 
            
            DECLARE 
                l_path GAME_MANAGER_PKG.t_path; 
                l_solution GAME_MANAGER_PKG.t_path; 
                l_initial_node GAME_MANAGER_PKG.t_node; 
                l_threshold NUMBER; 
                l_result NUMBER; 
            BEGIN 
                init_target_positions(state_to_table(l_target_state), l_board_size); 
                l_initial_node.board_state := state_to_table(l_shuffled_board); 
                l_initial_node.g_cost := 0; 
                l_initial_node.h_cost := calculate_heuristic(l_initial_node.board_state); 
                l_path(1) := l_initial_node; 
                l_threshold := l_initial_node.h_cost; 
                
                LOOP 
                    l_result := search(l_path, 0, l_threshold, l_solution); 
                    IF l_result = -1 THEN EXIT; END IF; 
                    l_threshold := l_result; 
                    IF l_threshold > 80 THEN l_solution.DELETE; EXIT; END IF; 
                END LOOP; 
                
                l_optimal_moves := l_solution.COUNT - 1; 
            END; 
        END; 

        INSERT INTO DAILY_CHALLENGES (
            CHALLENGE_ID, CHALLENGE_DATE, BOARD_SIZE, SHUFFLE_MOVES, BOARD_STATE, OPTIMAL_MOVES
        ) VALUES (
            DAILY_CHALLENGES_SEQ.NEXTVAL, l_next_day, l_board_size, l_shuffle_moves, l_shuffled_board, l_optimal_moves
        );
        COMMIT;
    END create_daily_challenge;

    ----------------------------------------------------------------------------
    -- РЕАЛИЗАЦИЯ: ПРИВАТНЫЕ УТИЛИТЫ
    ----------------------------------------------------------------------------
    FUNCTION get_game_state_json(p_game_id IN NUMBER) RETURN CLOB 
    AS 
        l_json_clob           CLOB;
        l_game                GAMES%ROWTYPE;
        l_current_board_state VARCHAR2(1000);
        l_image_url           VARCHAR2(256);
    BEGIN
        SELECT * INTO l_game FROM GAMES WHERE GAME_ID = p_game_id;

        IF l_game.STATUS = 'SOLVED' THEN
             l_current_board_state := ''; 
            FOR i IN 1..(l_game.BOARD_SIZE * l_game.BOARD_SIZE - 1) LOOP 
                l_current_board_state := l_current_board_state || i || ','; 
            END LOOP; 
            l_current_board_state := l_current_board_state || '0'; 
        ELSE
            SELECT BOARD_STATE
            INTO l_current_board_state
            FROM MOVE_HISTORY
            WHERE GAME_ID = p_game_id AND MOVE_ORDER = l_game.CURRENT_MOVE_ORDER;
        END IF;
        
        IF l_game.IMAGE_ID IS NOT NULL THEN
            l_image_url := '/api/image/' || l_game.IMAGE_ID;
        ELSE
            l_image_url := NULL;
        END IF;

        SELECT
            JSON_OBJECT(
                'sessionId'  VALUE l_game.GAME_ID,
                'boardSize'  VALUE l_game.BOARD_SIZE,
                'boardState' VALUE JSON_QUERY('[' || l_current_board_state || ']', '$'),
                'moves'      VALUE l_game.MOVE_COUNT,
                'startTime'  VALUE TO_CHAR(l_game.START_TIME, 'YYYY-MM-DD"T"HH24:MI:SS'),
                'status'     VALUE l_game.STATUS,
                'imageUrl'   VALUE l_image_url,
                'stars'      VALUE l_game.STARS_EARNED,
                'gameMode'   VALUE l_game.GAME_MODE
            )
        INTO l_json_clob
        FROM dual;

        RETURN l_json_clob;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN '{"status":"error", "message":"Session not found or history missing"}';
    END get_game_state_json;
    
    FUNCTION calculate_heuristic(p_board GAME_MANAGER_PKG.t_board) RETURN NUMBER 
    IS
        l_heuristic   NUMBER := 0;
        l_current_pos PLS_INTEGER;
        l_target_pos  PLS_INTEGER;
        l_current_row PLS_INTEGER;
        l_current_col PLS_INTEGER;
        l_target_row  PLS_INTEGER;
        l_target_col  PLS_INTEGER;
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
    
    FUNCTION state_to_table(p_state IN VARCHAR2) RETURN GAME_MANAGER_PKG.t_board 
    IS
        l_string       VARCHAR2(32767) := p_state || ',';
        l_comma_index  PLS_INTEGER;
        l_start_index  PLS_INTEGER := 1;
        l_result_table GAME_MANAGER_PKG.t_board;
        i              PLS_INTEGER := 1;
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

    FUNCTION table_to_state(p_table IN GAME_MANAGER_PKG.t_board) RETURN VARCHAR2 
    IS
        l_state VARCHAR2(32767);
    BEGIN
        IF p_table.COUNT = 0 THEN 
            RETURN NULL; 
        END IF;
        
        FOR i IN p_table.FIRST..p_table.LAST LOOP
            l_state := l_state || p_table(i) || ',';
        END LOOP;
        
        RETURN RTRIM(l_state, ',');
    END table_to_state;
    
    FUNCTION is_state_in_path(
        p_path  GAME_MANAGER_PKG.t_path,
        p_board GAME_MANAGER_PKG.t_board
    ) RETURN BOOLEAN
    IS
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
    ) RETURN NUMBER
    IS
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
                        
                        IF l_res = -1 THEN 
                            RETURN -1; 
                        END IF;
                        
                        IF l_res < l_min_f THEN 
                            l_min_f := l_res; 
                        END IF;
                        
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
    ) RETURN NUMBER
    AS
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
            IF l_result = -1 THEN 
                EXIT; 
            END IF;
            l_threshold := l_result;
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
    
    PROCEDURE init_target_positions(p_target_board GAME_MANAGER_PKG.t_board, p_size NUMBER) 
    IS
    BEGIN
        g_board_size := p_size;
        FOR i IN 1 .. p_target_board.COUNT LOOP
            IF p_target_board(i) != 0 THEN
                g_target_positions(p_target_board(i)) := i;
            END IF;
        END LOOP;
    END init_target_positions;

    FUNCTION get_user_stats(
        p_user_id IN USERS.USER_ID%TYPE
    ) RETURN CLOB
    AS
        l_username      USERS.USERNAME%TYPE;
        l_total_stars   NUMBER;
        l_best_time     NUMBER;
        l_best_moves    NUMBER;
        l_json_clob     CLOB;
    BEGIN
        -- Получаем имя пользователя
        SELECT USERNAME INTO l_username FROM USERS WHERE USER_ID = p_user_id;

        -- Получаем статистику из решенных игр
        SELECT
            NVL(SUM(STARS_EARNED), 0),
            NVL(MIN(CASE WHEN STATUS = 'SOLVED' THEN DURATION_SECONDS END), 0),
            NVL(MIN(CASE WHEN STATUS = 'SOLVED' THEN MOVE_COUNT END), 0)
        INTO
            l_total_stars,
            l_best_time,
            l_best_moves
        FROM GAMES
        WHERE USER_ID = p_user_id AND STATUS = 'SOLVED';

        -- Формируем JSON-ответ
        SELECT JSON_OBJECT(
            'username'    VALUE l_username,
            'total_stars' VALUE l_total_stars,
            'best_time'   VALUE l_best_time,
            'best_moves'  VALUE l_best_moves
        )
        INTO l_json_clob
        FROM DUAL;
        
        RETURN l_json_clob;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Если у пользователя еще нет игр, возвращаем пустые данные
            SELECT JSON_OBJECT(
                'username'    VALUE l_username,
                'total_stars' VALUE 0,
                'best_time'   VALUE 0,
                'best_moves'  VALUE 0
            )
            INTO l_json_clob
            FROM DUAL;
            RETURN l_json_clob;
    END get_user_stats;
    
END GAME_MANAGER_PKG;