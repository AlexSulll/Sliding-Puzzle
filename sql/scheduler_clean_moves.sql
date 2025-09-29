BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'CLEANUP_EXPIRED_GAMES_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN GAME_MANAGER_PKG.cleanup_expired_games; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY; INTERVAL=5', -- Запускать каждые 5 минут
    enabled         => TRUE,
    comments        => 'Job to clean up expired game sessions and their move history.'
  );
END;
/