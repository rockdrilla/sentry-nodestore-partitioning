CALL nodestore.create_partitions(
    CURRENT_DATE - 90,
    CURRENT_DATE + 30
);
