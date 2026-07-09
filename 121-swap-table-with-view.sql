ALTER TABLE public.nodestore_node RENAME TO public.OLD_nodestore_node;

CREATE OR REPLACE VIEW public.nodestore_node AS
SELECT
    "id",
    encode("data", 'base64') AS "data",
    "timestamp"
FROM nodestore.data;

CREATE TRIGGER nodestore_insert_trigger
    INSTEAD OF INSERT ON public.nodestore_node
    FOR EACH ROW EXECUTE FUNCTION nodestore.insert_trigger_fn();

CREATE TRIGGER nodestore_delete_trigger
    INSTEAD OF DELETE ON public.nodestore_node
    FOR EACH ROW EXECUTE FUNCTION nodestore.delete_trigger_fn();

CREATE TRIGGER nodestore_update_trigger
    INSTEAD OF UPDATE ON public.nodestore_node
    FOR EACH ROW EXECUTE FUNCTION nodestore.update_trigger_fn();
