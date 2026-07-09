DO $$
DECLARE
    pg_cron_extname TEXT;
    nodestore_job_name TEXT;
    nodestore_job_id BIGINT;
BEGIN
    pg_cron_extname := 'pg_cron';
    nodestore_job_name := 'nodestore-create-partitions';

    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = pg_cron_extname
    ) THEN
        RAISE WARNING '% is not installed', pg_cron_extname;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM cron.job
        WHERE jobname = nodestore_job_name
    ) THEN
        RAISE NOTICE 'Job % already exists', nodestore_job_name;
        RETURN;
    END IF;

    SELECT cron.schedule(
        nodestore_job_name,
        '30 23 * * *', -- everyday at 23:30
        'CALL nodestore.create_partitions_daily()'
    ) INTO nodestore_job_id;

    RAISE NOTICE 'Scheduled job %, ID %', nodestore_job_name, nodestore_job_id;
END $$;
