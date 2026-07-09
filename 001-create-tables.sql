CREATE SCHEMA IF NOT EXISTS nodestore;
ALTER SCHEMA nodestore OWNER TO sentry;

--

CREATE TABLE nodestore.data (
    "id" TEXT NOT NULL,
    "data" BYTEA NOT NULL,
    "timestamp" TIMESTAMP WITH TIME ZONE NOT NULL
) PARTITION BY RANGE ("timestamp");
ALTER TABLE nodestore.data OWNER TO sentry;

ALTER TABLE nodestore.data ALTER COLUMN "id" SET STORAGE PLAIN;
ALTER TABLE nodestore.data ALTER COLUMN "data" SET STORAGE EXTENDED;
ALTER TABLE nodestore.data ALTER COLUMN "data" SET COMPRESSION lz4;

CREATE INDEX data_id_btree ON nodestore.data USING btree ("id");
CREATE INDEX data_id_pattern ON nodestore.data ("id" text_pattern_ops);
CREATE INDEX data_ts_brin ON nodestore.data USING brin ("timestamp");

--

CREATE OR REPLACE FUNCTION nodestore.id_route(id TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN id ~ '^[0-9a-f]{32}$' THEN left(id, 1) ELSE 'default' END;
$$;

CREATE TABLE nodestore.ids (
    "id" TEXT NOT NULL
) PARTITION BY LIST (nodestore.id_route("id"));
ALTER TABLE nodestore.ids OWNER TO sentry;

ALTER TABLE nodestore.ids ALTER COLUMN "id" SET STORAGE PLAIN;

DO $$
DECLARE
    c TEXT;
    part_name TEXT;
BEGIN
    FOREACH c IN ARRAY ARRAY['0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f']
    LOOP
        part_name := 'ids_part_' || c;

        EXECUTE format(
          'CREATE TABLE nodestore.%I PARTITION OF nodestore.ids FOR VALUES IN (%L)',
          part_name, c
        );
        EXECUTE format('ALTER TABLE nodestore.%I OWNER TO sentry',
          part_name
        );

        EXECUTE format(
          'CREATE UNIQUE INDEX %I ON nodestore.%I USING btree ("id")',
          part_name || '_idx', part_name
        );

        EXECUTE format(
          'CREATE INDEX %I ON nodestore.%I ("id" text_pattern_ops)',
          part_name || '_pattern', part_name
        );
    END LOOP;
END $$;

CREATE TABLE nodestore.ids_default_part PARTITION OF nodestore.ids DEFAULT;
ALTER TABLE nodestore.ids_default_part OWNER TO sentry;

CREATE UNIQUE INDEX ids_default_part_idx ON nodestore.ids_default_part USING btree ("id");
CREATE INDEX ids_default_part_pattern ON nodestore.ids_default_part ("id" text_pattern_ops);
