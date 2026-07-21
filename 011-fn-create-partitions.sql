CREATE OR REPLACE PROCEDURE nodestore.create_partitions(
    start_date DATE,
    end_date DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    cur_date DATE;
    part_name TEXT;
    start_of_day TIMESTAMPTZ;
    end_of_day TIMESTAMPTZ;
    partitions_created INTEGER;
    t_start TIMESTAMPTZ;
BEGIN
    IF start_date > end_date THEN
        RAISE EXCEPTION 'start_date (%) must be <= end_date (%)', start_date, end_date;
    END IF;

    partitions_created := 0;
    cur_date := start_date;

    WHILE cur_date <= end_date LOOP
        part_name := 'data_part_' || TO_CHAR(cur_date, 'YYYY_MM_DD');

        start_of_day := cur_date::TIMESTAMPTZ;
        end_of_day := (cur_date + 1)::TIMESTAMPTZ;

        IF EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'nodestore'
              AND c.relname = part_name
              AND c.relkind = 'r'
        ) THEN
            RAISE NOTICE 'Partition already exists: %', part_name;
        ELSE
            t_start := clock_timestamp();
            EXECUTE format(
              'CREATE TABLE IF NOT EXISTS nodestore.%I PARTITION OF nodestore.data FOR VALUES FROM (%L) TO (%L)',
              part_name, start_of_day, end_of_day);
            RAISE NOTICE '[timing] create partition: % s', EXTRACT(EPOCH FROM clock_timestamp() - t_start);

            EXECUTE format('ALTER TABLE nodestore.%I OWNER TO sentry',
              part_name);

            partitions_created := partitions_created + 1;
            RAISE NOTICE 'Created partition: % (range: % to %)',
                part_name, start_of_day, end_of_day;
        END IF;

        cur_date := cur_date + 1;
    END LOOP;

    RAISE NOTICE 'Procedure completed. Total partitions created: %', partitions_created;
END;
$$;
