CREATE OR REPLACE PROCEDURE nodestore.recreate_unique_ids()
LANGUAGE plpgsql
AS $$
DECLARE
    partition_rec RECORD;
    part_rows BIGINT;
    t_start TIMESTAMPTZ;
BEGIN
    RAISE NOTICE 'Truncating nodestore.ids';
    TRUNCATE TABLE nodestore.ids;

    FOR partition_rec IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_inherits i ON i.inhrelid = c.oid
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE n.nspname = 'nodestore'
          AND parent.relname = 'data'
          AND c.relkind = 'r'
          AND c.relname LIKE 'data_part_%'
        ORDER BY c.relname
    LOOP
        RAISE NOTICE 'Processing partition: %', partition_rec.relname;

        t_start := clock_timestamp();
        EXECUTE format(
            'WITH inserted AS (
                INSERT INTO nodestore.ids ("id")
                SELECT "id" FROM nodestore.%I
                RETURNING 1
            )
            SELECT COUNT(*)
            FROM inserted',
            partition_rec.relname
        )
        INTO part_rows;
        part_rows := COALESCE(part_rows, 0);

        RAISE NOTICE 'Inserted "id"s: %', part_rows;
        RAISE NOTICE '[timing] select/insert: %.3f s', EXTRACT(EPOCH FROM clock_timestamp() - t_start);
    END LOOP;
END;
$$;
