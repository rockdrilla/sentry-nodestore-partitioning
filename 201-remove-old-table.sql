-- comment this section entirely
DO $$
BEGIN
    RAISE EXCEPTION 'Change this file!';
END;
$$;

-- uncomment this section
-- DROP TABLE IF EXISTS public.OLD_nodestore_node CASCADE;

DROP PROCEDURE IF EXISTS nodestore.copy_data_to_real( TIMESTAMPTZ, TIMESTAMPTZ, INTEGER );
