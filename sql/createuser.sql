ALTER SESSION SET CONTAINER = XEPDB1;

CREATE USER PUZZLEGAME IDENTIFIED BY qwertylf1;

-- Право на подключение к БД
GRANT CREATE SESSION TO puzzlegame;

-- Права на создание объектов схемы
GRANT CREATE TABLE, CREATE SEQUENCE, CREATE PROCEDURE TO puzzlegame;

-- Выделяем место для хранения данных (для разработки это самый простой способ)
GRANT UNLIMITED TABLESPACE TO puzzlegame;

GRANT DBA TO puzzlegame