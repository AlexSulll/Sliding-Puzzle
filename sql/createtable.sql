-- Последовательности для генерации ID
CREATE SEQUENCE users_seq START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE game_sessions_seq START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE move_history_seq START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE game_archive_seq START WITH 1 INCREMENT BY 1;

-- Таблица пользователей (упрощенная)
CREATE TABLE USERS (
    USER_ID       NUMBER DEFAULT users_seq.NEXTVAL PRIMARY KEY,
    USERNAME      VARCHAR2(50) UNIQUE NOT NULL,
    CREATED_AT    DATE DEFAULT SYSDATE
);

-- Для примера создадим одного пользователя
INSERT INTO USERS (USERNAME) VALUES ('player1');
COMMIT;

-- Таблица активных игровых сессий
CREATE TABLE GAME_SESSIONS (
    SESSION_ID    NUMBER DEFAULT game_sessions_seq.NEXTVAL PRIMARY KEY,
    USER_ID       NUMBER REFERENCES USERS(USER_ID),
    BOARD_SIZE    NUMBER(1) NOT NULL,
    BOARD_STATE   VARCHAR2(1000) NOT NULL, -- Состояние доски в виде CSV: "1,2,3,4,5,6,7,8,0"
    TARGET_STATE  VARCHAR2(1000) NOT NULL, -- Целевое состояние для проверки победы
    MOVE_COUNT    NUMBER DEFAULT 0,
    START_TIME    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    STATUS        VARCHAR2(20) DEFAULT 'ACTIVE' CHECK (STATUS IN ('ACTIVE', 'SOLVED', 'ABANDONED'))
);

-- Таблица истории ходов для Undo
CREATE TABLE MOVE_HISTORY (
    MOVE_ID       NUMBER DEFAULT move_history_seq.NEXTVAL PRIMARY KEY,
    SESSION_ID    NUMBER REFERENCES GAME_SESSIONS(SESSION_ID) ON DELETE CASCADE,
    BOARD_STATE   VARCHAR2(1000) NOT NULL,
    MOVE_ORDER    NUMBER
);

-- Таблица архива завершенных игр
CREATE TABLE GAME_ARCHIVE (
    ARCHIVE_ID    NUMBER DEFAULT game_archive_seq.NEXTVAL PRIMARY KEY,
    USER_ID       NUMBER REFERENCES USERS(USER_ID),
    BOARD_SIZE    NUMBER(1),
    MOVES_MADE    NUMBER,
    DURATION_SECONDS NUMBER,
    RESULT        VARCHAR2(20) NOT NULL,
    COMPLETED_AT  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Добавляем информацию о режиме игры и картинках
ALTER TABLE GAME_SESSIONS ADD (
    GAME_MODE VARCHAR2(10) DEFAULT 'NUMBERS' NOT NULL, -- 'NUMBERS' or 'IMAGE'
    IMAGE_URL VARCHAR2(255)
);

-- Добавляем больше деталей в архив для рейтингов
ALTER TABLE GAME_ARCHIVE ADD (
    GAME_MODE VARCHAR2(10) DEFAULT 'NUMBERS' NOT NULL,
    IS_DAILY_CHALLENGE NUMBER(1) DEFAULT 0, -- 0 for false, 1 for true
    STARS_EARNED NUMBER(1) DEFAULT 0
);

-- Создаем таблицу для ежедневных челленджей
CREATE TABLE DAILY_CHALLENGES (
    CHALLENGE_DATE DATE PRIMARY KEY,
    BOARD_SIZE NUMBER NOT NULL,
    SHUFFLE_MOVES NUMBER NOT NULL,
    TARGET_STATE VARCHAR2(1000) NOT NULL
);

-- Для примера добавим челлендж на сегодня (замените SYSDATE на нужную дату при тестировании)
-- TRUNC(SYSDATE) обрезает время, оставляя только дату
INSERT INTO DAILY_CHALLENGES (CHALLENGE_DATE, BOARD_SIZE, SHUFFLE_MOVES, TARGET_STATE)
VALUES (TRUNC(SYSDATE), 4, 70, '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0');
COMMIT;

ALTER TABLE USERS ADD (
    PASSWORD_HASH VARCHAR2(256)
);

-- Установим хэш для нашего гостевого/тестового пользователя 'player1'
-- Хэш для пароля 'guest' (мы будем использовать SHA-256)
-- В реальной системе этот хэш генерировался бы при создании пользователя
UPDATE USERS
SET PASSWORD_HASH = '84983C60F7DA2012B130B9AA63BF45994A17945C45A344585596F31D4539245E' -- SHA256 хэш от 'guest'
WHERE USERNAME = 'player1';
COMMIT;

-- 1. Добавляем в таблицу сессий колонку для хранения истории отмененных ходов (для Redo)
-- Будем хранить в виде JSON-массива состояний доски. CLOB используется для больших объемов.
ALTER TABLE GAME_SESSIONS ADD (
    REDO_STACK CLOB
);

-- 2. Добавляем в архив сложность, чтобы по ней можно было фильтровать рейтинги
ALTER TABLE GAME_ARCHIVE ADD (
    DIFFICULTY_LEVEL NUMBER
);

-- Добавляем в таблицу челленджей колонку для хранения оптимального числа ходов
ALTER TABLE DAILY_CHALLENGES ADD (
    OPTIMAL_MOVES NUMBER
);

-- Обновим наш тестовый челлендж (условно поставим 42 хода)
-- В реальной системе это значение нужно вычислить солвером один раз при создании челленджа.
UPDATE DAILY_CHALLENGES
SET OPTIMAL_MOVES = 42
WHERE CHALLENGE_DATE = TRUNC(SYSDATE);

COMMIT;

ALTER TABLE GAME_SESSIONS ADD (
    DIFFICULTY_LEVEL NUMBER
);