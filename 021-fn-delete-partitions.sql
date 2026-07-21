CREATE OR REPLACE PROCEDURE nodestore.delete_old_partitions(
    retention_days INTEGER DEFAULT 90,
    batch_size INTEGER DEFAULT 5000
)
LANGUAGE plpgsql
AS $$
DECLARE
    partition_rec RECORD;
    partition_date DATE;
    detached_names TEXT[] := '{}';
    partition_name TEXT;
    total_part_rows BIGINT;
    total_deleted_ids BIGINT;
    last_id TEXT;
    part_rows BIGINT;
    part_deleted_ids BIGINT;
    total_dropped BIGINT := 0;
    partitions_dropped INTEGER := 0;
    t_start TIMESTAMPTZ;
BEGIN
    IF retention_days <= 0 THEN
        RAISE EXCEPTION 'retention_days must be positive, got %', retention_days;
    END IF;

    RAISE NOTICE 'Deleting partitions older than % days (cutoff: %)',
      retention_days, CURRENT_DATE - retention_days;

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
        partition_date := TO_DATE(
          substring(partition_rec.relname FROM 'data_part_(\d{4}_\d{2}_\d{2})'),
          'YYYY_MM_DD'
        );

        IF partition_date >= (CURRENT_DATE - retention_days) THEN
            CONTINUE;
        END IF;

        -- Phase 1: detach only — fast, minimal lock
        RAISE NOTICE 'Detaching: %', partition_rec.relname;
        t_start := clock_timestamp();
        EXECUTE format('ALTER TABLE nodestore.data DETACH PARTITION nodestore.%I', partition_rec.relname);
        RAISE NOTICE '[timing] detach: % s', EXTRACT(EPOCH FROM clock_timestamp() - t_start);

        detached_names := array_append(detached_names, partition_rec.relname);
    END LOOP;

    -- Phase 2: batch-delete IDs and drop each detached partition
    FOREACH partition_name IN ARRAY detached_names LOOP
        total_part_rows := 0;
        total_deleted_ids := 0;
        last_id := '';

        RAISE NOTICE 'Deleting stale "id"s from: %', partition_name;
        t_start := clock_timestamp();
        LOOP
            part_rows := 0;
            part_deleted_ids := 0;

            EXECUTE format(
                'WITH batch AS (
                    SELECT "id"
                    FROM nodestore.%I
                    WHERE "id" > $1
                    ORDER BY "id"
                    LIMIT $2
                ),
                deleted AS (
                    DELETE FROM nodestore.ids u
                    USING batch b
                    WHERE u."id" = b."id"
                    RETURNING 1
                ),
                last_row AS (
                    SELECT "id" FROM batch
                    ORDER BY "id" DESC
                    LIMIT 1
                )
                SELECT
                    COALESCE(lr."id", $1),
                    (SELECT COUNT(*) FROM batch),
                    (SELECT COUNT(*) FROM deleted)
                FROM last_row lr',
                partition_name
            )
            INTO last_id, part_rows, part_deleted_ids
            USING last_id, batch_size;

            last_id := COALESCE(last_id, 'NULL');
            part_rows := COALESCE(part_rows, 0);
            part_deleted_ids := COALESCE(part_deleted_ids, 0);

            -- RAISE NOTICE '[debug] part_rows %, part_deleted_ids %, last_id %', part_rows, part_deleted_ids, last_id;
            EXIT WHEN part_rows = 0;

            total_part_rows := total_part_rows + part_rows;
            total_deleted_ids := total_deleted_ids + part_deleted_ids;
            COMMIT;
        END LOOP;
        RAISE NOTICE 'Deleted "id"s: %', total_deleted_ids;
        RAISE NOTICE '[timing] batch delete: % s', EXTRACT(EPOCH FROM clock_timestamp() - t_start);

        RAISE NOTICE 'Dropping table: %', partition_name;
        t_start := clock_timestamp();
        EXECUTE format('DROP TABLE IF EXISTS nodestore.%I CASCADE', partition_name);
        RAISE NOTICE 'Dropped: % (% rows)', partition_name, total_part_rows;
        RAISE NOTICE '[timing] drop table: % s', EXTRACT(EPOCH FROM clock_timestamp() - t_start);

        total_dropped := total_dropped + total_part_rows;
        partitions_dropped := partitions_dropped + 1;
    END LOOP;

    RAISE NOTICE 'Dropped % partitions, % rows', partitions_dropped, total_dropped;

    IF partitions_dropped > 0 THEN
        RAISE NOTICE 'Analyzing: nodestore.ids';
        t_start := clock_timestamp();
        ANALYZE ( VERBOSE ) nodestore.ids;
        RAISE NOTICE '[timing] analyze: % s', EXTRACT(EPOCH FROM clock_timestamp() - t_start);
    END IF;
END;
$$;
