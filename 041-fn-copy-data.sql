CREATE OR REPLACE PROCEDURE nodestore.copy_data_to_real(
    start_date TIMESTAMPTZ,
    end_date TIMESTAMPTZ,
    batch_size INTEGER DEFAULT 5000
)
LANGUAGE plpgsql
AS $$
DECLARE
    preflight_rows INTEGER;
    batch_rows INTEGER;
    total_copied BIGINT := 0;
    batch_count INTEGER := 0;
    last_timestamp TIMESTAMPTZ := start_date;
    last_id TEXT := '';
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'nodestore_node'
          AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'nodestore_node is not a table (probably a view). Migration already completed?';
    END IF;

    RAISE NOTICE 'Starting copy from % to %', start_date, end_date;

    LOOP
        preflight_rows := 0;
        batch_rows := 0;

        WITH
        preflight AS (
            SELECT "id", "timestamp"
            FROM public.nodestore_node
            WHERE "timestamp" >= last_timestamp
              AND "timestamp" < end_date
            ORDER BY "timestamp"
            LIMIT batch_size
        ),
        batch AS (
            SELECT p."id", p."timestamp"
            FROM preflight p
            WHERE NOT EXISTS (
                SELECT 1 FROM nodestore.ids i
                WHERE i."id" = p."id"
              )
            ORDER BY p."timestamp"
        ),
        inserted_ids AS (
            INSERT INTO nodestore.ids ("id")
            SELECT DISTINCT "id" FROM batch
            RETURNING 1
        ),
        inserted_rows AS (
            INSERT INTO nodestore.data ("id", "timestamp", "data")
            SELECT b."id", b."timestamp", DECODE(u."data", 'base64')
            FROM batch b, public.nodestore_node u
            WHERE b."id" = u."id"
              AND b."timestamp" = u."timestamp"
            RETURNING 1
        ),
        last_row AS (
            SELECT "id", "timestamp"
            FROM preflight
            ORDER BY "timestamp" DESC
            LIMIT 1
        )
        SELECT
            COALESCE(lr."id", last_id),
            COALESCE(lr."timestamp", last_timestamp),
            (SELECT COUNT(*) FROM preflight),
            (SELECT COUNT(*) FROM batch)
        INTO last_id, last_timestamp, preflight_rows, batch_rows
        FROM last_row lr;

        last_id := COALESCE(last_id, 'NULL');
        last_timestamp := COALESCE(last_timestamp, end_date);
        preflight_rows := COALESCE(preflight_rows, 0);
        batch_rows := COALESCE(batch_rows, 0);

        -- RAISE NOTICE '[debug] preflight_rows %, batch_rows %, last_timestamp %, last_id %', preflight_rows, batch_rows, last_timestamp, last_id;
        EXIT WHEN preflight_rows = 0;

        batch_count := batch_count + 1;
        total_copied := total_copied + batch_rows;

        RAISE NOTICE 'Batch %: copied % rows (total: %), last: (%, %)',
          batch_count, batch_rows, total_copied, last_timestamp, last_id;

        COMMIT;
    END LOOP;

    RAISE NOTICE 'Copy completed! Total copied: % rows in % batches',
      total_copied, batch_count;
END;
$$;
