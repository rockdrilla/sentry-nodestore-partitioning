CREATE OR REPLACE PROCEDURE nodestore.create_partitions_daily()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL nodestore.create_partitions( CURRENT_DATE - 1, CURRENT_DATE + 7 );
END;
$$;
