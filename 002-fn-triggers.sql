CREATE OR REPLACE FUNCTION nodestore.insert_trigger_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO nodestore.ids ("id")
    VALUES (NEW."id");

    NEW."timestamp" := COALESCE(NEW."timestamp", NOW());

    INSERT INTO nodestore.data ("id", "data", "timestamp")
    VALUES (NEW."id", DECODE(NEW."data", 'base64'), NEW."timestamp");

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION nodestore.delete_trigger_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- "sentry cleanup" sends bulk DELETEs (id = ANY(ARRAY[...])).
    -- Data removal is currently handled by retention policy procedures:
    --   manually: nodestore.delete_old_partitions( [retention_days, [batch_size]] )
    --   scheduled in either way: nodestore.delete_partitions_daily()

    -- NB: do NOT flood server logs
    -- RAISE WARNING 'DELETE is ignored.';
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION nodestore.update_trigger_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- NB: "id" and "timestamp" are immutable

    IF OLD."id" IS DISTINCT FROM NEW."id" THEN
        RAISE EXCEPTION 'Cannot change id from % to %', OLD."id", NEW."id";
    END IF;

    IF OLD."timestamp" IS DISTINCT FROM NEW."timestamp" THEN
        RAISE EXCEPTION 'Cannot change timestamp from % to %', OLD."timestamp", NEW."timestamp";
    END IF;

    -- only issue UPDATE when "data" is changed
    IF OLD."data" IS DISTINCT FROM NEW."data" THEN
        UPDATE nodestore.data
        SET "data" = DECODE(NEW."data", 'base64')
        WHERE "id" = OLD."id";
    END IF;

    RETURN NEW;
END;
$$;
