/*
 * Apply foreign keys that exist on the given parent to the given child table
 */
CREATE FUNCTION apply_foreign_keys(p_parent_table text, p_child_table text DEFAULT NULL, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context          text;
ex_detail           text;
ex_hint             text;
ex_message          text;
v_job_id            bigint;
v_jobmon            text;
v_jobmon_schema     text;
v_old_search_path   text;
v_ref_schema        text;
v_ref_table         text;
v_row               record;
v_schemaname        text;
v_sql               text;
v_step_id           bigint;
v_tablename         text;

BEGIN

SELECT jobmon INTO v_jobmon FROM @extschema@.part_config WHERE parent_table = p_parent_table;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_jobmon_schema||''',''false'')';
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job('PARTMAN APPLYING FOREIGN KEYS: '||p_parent_table);
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Checking if target child table exists');
END IF;

SELECT schemaname, tablename INTO v_schemaname, v_tablename 
FROM pg_catalog.pg_tables 
WHERE schemaname||'.'||tablename = p_child_table;

IF v_tablename IS NULL THEN
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'CRITICAL', 'Target child table ('||v_child_table||') does not exist.');
        PERFORM fail_job(v_job_id);
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
    END IF;
    RAISE EXCEPTION 'Target child table (%.%) does not exist.', v_schemaname, v_tablename;
    RETURN;
ELSE
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

FOR v_row IN 
    SELECT n.nspname||'.'||cl.relname AS ref_table
        , '"'||string_agg(att.attname, '","')||'"' AS ref_column
        , '"'||string_agg(att2.attname, '","')||'"' AS child_column
        , keys.condeferred
        , keys.condeferrable
        , keys.confupdtype
        , keys.confdeltype
        , keys.confmatchtype
    FROM
        ( SELECT unnest(con.conkey) as ref
                , unnest(con.confkey) as child
                , con.confrelid
                , con.conrelid
                , con.condeferred
                , con.condeferrable
                , con.confupdtype
                , con.confdeltype
                , con.confmatchtype
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
          JOIN pg_catalog.pg_constraint con ON c.oid = con.conrelid
          WHERE n.nspname ||'.'|| c.relname = p_parent_table
          AND con.contype = 'f'
          ORDER BY con.conkey
    ) keys
    JOIN pg_catalog.pg_class cl ON cl.oid = keys.confrelid
    JOIN pg_catalog.pg_namespace n ON cl.relnamespace = n.oid
    JOIN pg_catalog.pg_attribute att ON att.attrelid = keys.confrelid AND att.attnum = keys.child
    JOIN pg_catalog.pg_attribute att2 ON att2.attrelid = keys.conrelid AND att2.attnum = keys.ref
    GROUP BY n.nspname, cl.relname, keys.condeferred, keys.condeferrable, keys.confupdtype, keys.confdeltype, keys.confmatchtype
LOOP
    SELECT schemaname, tablename INTO v_ref_schema, v_ref_table FROM pg_tables WHERE schemaname||'.'||tablename = v_row.ref_table;
    v_sql := format('ALTER TABLE %I.%I ADD FOREIGN KEY (%s) REFERENCES %I.%I (%s)', 
        v_schemaname, v_tablename, v_row.child_column, v_ref_schema, v_ref_table, v_row.ref_column);
    CASE
        WHEN v_row.confmatchtype = 'f' THEN
            v_sql := v_sql || ' MATCH FULL ';
        WHEN v_row.confmatchtype = 's' THEN
            v_sql := v_sql || ' MATCH SIMPLE ';
        WHEN v_row.confmatchtype = 'p' THEN
            v_sql := v_sql || ' MATCH PARTIAL ';
    END CASE;
    CASE 
        WHEN v_row.confupdtype = 'a' THEN
            v_sql := v_sql || ' ON UPDATE NO ACTION ';
        WHEN v_row.confupdtype = 'r' THEN
            v_sql := v_sql || ' ON UPDATE RESTRICT ';
        WHEN v_row.confupdtype = 'c' THEN
            v_sql := v_sql || ' ON UPDATE CASCADE ';
        WHEN v_row.confupdtype = 'n' THEN
            v_sql := v_sql || ' ON UPDATE SET NULL ';
        WHEN v_row.confupdtype = 'd' THEN
            v_sql := v_sql || ' ON UPDATE SET DEFAULT ';
    END CASE;
    CASE
        WHEN v_row.confdeltype = 'a' THEN
            v_sql := v_sql || ' ON DELETE NO ACTION ';
        WHEN v_row.confdeltype = 'r' THEN
            v_sql := v_sql || ' ON DELETE RESTRICT ';
         WHEN v_row.confdeltype = 'c' THEN
            v_sql := v_sql || ' ON DELETE CASCADE ';
         WHEN v_row.confdeltype = 'n' THEN
            v_sql := v_sql || ' ON DELETE SET NULL ';
         WHEN v_row.confdeltype = 'd' THEN
            v_sql := v_sql || ' ON DELETE SET DEFAULT ';
    END CASE;
    CASE
        WHEN v_row.condeferrable = true AND v_row.condeferred = true THEN
            v_sql := v_sql || ' DEFERRABLE INITIALLY DEFERRED ';
        WHEN v_row.condeferrable = false AND v_row.condeferred = false THEN
            v_sql := v_sql || ' NOT DEFERRABLE ';
        WHEN v_row.condeferrable = true AND v_row.condeferred = false THEN
            v_sql := v_sql || ' DEFERRABLE INITIALLY IMMEDIATE ';
    END CASE;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Applying FK: '||v_sql);
    END IF;

    EXECUTE v_sql;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'FK applied');
    END IF;

END LOOP;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
    EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE APPLYING FOREIGN KEYS: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;

