CREATE OR REPLACE PROCEDURE nodestore.delete_partitions_daily()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL nodestore.delete_old_partitions( 90 );
END;
$$;
