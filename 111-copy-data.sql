-- comment this section entirely
DO $$
BEGIN
    RAISE EXCEPTION 'Change this file!';
END;
$$;

-- uncomment this section or write your own
-- DO $$
-- DECLARE
--     v_start TIMESTAMPTZ;
--     v_end TIMESTAMPTZ;
-- BEGIN
--     SELECT MIN("timestamp"), MAX("timestamp")
--     INTO v_start, v_end
--     FROM public.nodestore_node;

--     IF v_start IS NULL OR v_end IS NULL THEN
--         RAISE EXCEPTION 'No data found in nodestore_node';
--     END IF;

--     CALL nodestore.copy_data_to_real( v_start, v_end );
-- END;
-- $$;
