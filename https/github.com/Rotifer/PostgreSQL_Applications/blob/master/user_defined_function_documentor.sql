-- user_defined_function_documentor.sql
-- Set of functions for commenting other functions and for parsing and returning documentation.
-- See: https://github.com/Rotifer/PostgreSQL_Applications/blob/master/documenting_user_defined_functions.md

CREATE OR REPLACE FUNCTION create_function_comment_statement(p_function_name TEXT, p_arg_types TEXT[], p_purpose TEXT, p_example TEXT, p_notes TEXT DEFAULT '')
RETURNS TEXT
AS
$$
DECLARE
  l_comment_date DATE := CURRENT_DATE;
  l_commenter_username TEXT := CURRENT_USER;
  l_comment TEXT := '{"Purpose": "%s", "Example": "%s", "Comment_Date": "%s", "Commenter_Username": "%s", "Notes": "%s"}';
  l_comment_statement TEXT := 'COMMENT ON FUNCTION %s(%s) IS $qq$%s$qq$';
  l_comment_as_jsonb JSONB;
BEGIN
  l_comment := FORMAT(l_comment, p_purpose, p_example, l_comment_date::TEXT, l_commenter_username, p_notes);
  l_comment_statement := FORMAT(l_comment_statement, p_function_name, ARRAY_TO_STRING(p_arg_types, ','), l_comment);
  l_comment_as_jsonb := l_comment::JSONB;
  EXECUTE l_comment_statement;
  RETURN l_comment_statement;
END;
$$
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER;

SELECT create_function_comment_statement('create_function_comment_statement', 
                                         ARRAY['TEXT', 'TEXT[]', 'TEXT', 'TEXT', 'TEXT'], 
                                         'Adds structured comments to user-defined functions so that the comments, although stored as text, can be returned as JSONB.', 
                                         $$SELECT 1; -- Dummy example for this function$$, 
                                         'This function executes dynamic SQL so it is set as *SECURITY INVOKER* and it should only be executed by users who can create functions.' ||
                                         'It checks that the comment text can be converted to JSONB and an error will arise if the it cannot be converted to JSONB' || 
                                         ' (line: *l_comment_as_jsonb := l_comment::JSONB;)*. Double quotes have special meaning in JSON so are disallowed in the input string arguments.' ||
                                         'To allow for single quotes in the example SQL, double dollar ($$) quoting is used to enclose the example SQL statement.'
                                         'Remember to include the schema name as part of the function name if it is not the default <public>. As PL/pgSQL allows function over-loading,' ||
                                         ' you need to ensure that the array of argument types exactly matches the function you wish to comment.');
                                         

CREATE OR REPLACE FUNCTION get_details_for_function(p_schema_name TEXT, p_function_name TEXT)
RETURNS  TABLE(function_name TEXT, function_parameters TEXT, function_oid OID, function_comment JSONB)
AS
$$
BEGIN
  RETURN QUERY
  SELECT 
    n.nspname || '.' || p.proname function_name, 
    pg_get_function_arguments(p.oid),
    p.oid,
    d.description::JSONB function_comment 
  FROM pg_proc p
    INNER JOIN pg_namespace n ON n.oid = p.pronamespace
      LEFT JOIN pg_description As d ON (d.objoid = p.oid )
  WHERE
    n.nspname = p_schema_name
   AND
     p.proname = p_function_name                          ;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

SELECT create_function_comment_statement('get_details_for_function', 
                                         ARRAY['TEXT', 'TEXT'], 
                                         'Returns a table of information for a given schema name  and function name.', 
                                         $$SELECT * FROM get_details_for_function('public', 'create_function_comment_statement');$$, 
                                         'Because PL/pgSQL supports function over-loading, this function can return more than one row' || 
                                         'for a given schema name and function name. The actual comment is returned as JSONB in the column named <function_comment>.');

CREATE OR REPLACE FUNCTION get_text_as_jsonb(p_text TEXT, p_dummy_key_name TEXT)                                      
RETURNS JSONB
AS
$$
BEGIN
  RETURN p_text::JSONB;
EXCEPTION
  WHEN invalid_text_representation THEN
    p_text := REPLACE(p_text, '"', '*');
    p_text := REPLACE(p_text, E'\n', ' ');
    RETURN (FORMAT('{"%s":"%s"}', p_dummy_key_name, p_text))::JSONB;                                         
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

SELECT create_function_comment_statement('get_text_as_jsonb', 
                                         ARRAY['TEXT', 'TEXT'], 
                                         'Returns input text as JSONB using the second argument as the key to the text', 
                                         $$SELECT get_text_as_jsonb('not json'::TEXT, 'COMMENT');$$, 
                                         'This function should be able to convert any input text into JSONB. ' ||
                                        'It replaces double quotes with * and removes embedded new lines which ' ||
                                        'seem to cause problems in Postgres JSONB.' ||
                                        'Note how it uses exception handling only when the input text cannot be converted ' ||
                                        'directly to JSONB. Comments added using *create_function_comment_statement* ' ||
                                        'will not trigger the exception.'); 
                                        
CREATE OR REPLACE FUNCTION get_function_details_for_schema(p_schema_name TEXT, p_dummy_key TEXT)
RETURNS TABLE(function_name TEXT, function_comment JSONB, function_oid OID)
AS
$$                                         
BEGIN
  RETURN QUERY
  SELECT 
    n.nspname || '.' || p.proname function_name, 
    get_text_as_jsonb(d.description, p_dummy_key) function_comment,
    p.oid function_oid
  FROM
    pg_proc p
    INNER JOIN pg_namespace n ON n.oid = p.pronamespace
    LEFT JOIN pg_description As d ON (d.objoid = p.oid )
  WHERE
    n.nspname = p_schema_name;
END;                                         
$$                                         
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

SELECT create_function_comment_statement('get_function_details_for_schema',
                                        ARRAY['TEXT', 'TEXT'],
                                        'Returns a table of all the functions in a given schema with their comments as JSONB.',
                                        $$SELECT * FROM get_function_details_for_schema('public', 'NON_STANDARD_COMMENT');$$,
                                        'If the comments are not in the format generated by function *create_function_comment_statement*, ' ||
                                        'they are converted to JSONB and the second argument given is used as the key. ' ||
                                        'The returned JSONB can be parsed using standard operators such as *->>* to extract ' ||
                                        'the constituent parts. ' ||
                                        'The function OID is a unique identifier that is especially useful for identifying overloaded functions.' ||
                                        'It can be used as an argument to system catalog information functions such as *pg_get_functiondef(func_oid)*.');
