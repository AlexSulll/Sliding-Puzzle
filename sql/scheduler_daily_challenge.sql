BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'DAILY_CHALLENGE_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN GAME_MANAGER_PKG.create_daily_challenge; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY; BYHOUR=0; BYMINUTE=0; BYSECOND=0',
    enabled         => TRUE,
    comments        => 'Создание ежедневного челленджа в полночь'
  );
END;
/