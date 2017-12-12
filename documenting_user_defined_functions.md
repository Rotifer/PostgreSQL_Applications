# Documenting PL/pgSQL Code

## Summary
Over the years I have written quite a few PostgreSQL user-defined functions (UDFs) mainly in PL/pgSQL but also, as the need arises, in PL/Python. If you do likewise, you might be interested in what I have written here where I try to describe an approach to writing standardised database comments to document these functions. Instead of issuing a series of *COMMENT ON FUNCTION* statements to do this, I have written one PL/pgSQL function to create the comment text and then execute the full *COMMENT ON* statement for me in a manner that creates a comment format that can be converted to JSONB and then parsed to extract key information in a standardised and usable manner. Along the way, I demonstrate a few useful PL/pgSQL tricks to do things like build and execute dynamic SQL, parse JSONB and use PostgreSQL system catalogs and ANISI SQL standard *INFORMATION_SCHEMA* views to retrieve information about UDFs. I firmly believe that when comments are used consistently and properly, they are an indespensable mechanism for database self-documentation. 

Written by: Michael Maguire  
Written: 2017-12-11  
Email: mick@javascript-spreadsheet-programming.com  
Twitter: https://twitter.com/michaelfmaguir1  

## The *COMMENT ON* command
Like Oracle, PostgreSQL supports the non-SQL standard *COMMENT ON* command to add custom documentation to pretty much any database object that the user can create. Such objects can be tables, views, views or tables columns, triggers, user-defined functions and so on. The only major relational database management system (RDBMS) that I have used that does not support this feature in some form is SQLite where I expect it is omitted to save space. Once written in PostgreSQL, comments can be retrieved from the ANSI SQL *INFORMATION_SCHEMA* or the system catalogs as I will demonstrate later.

## Why I use database object comments to document my PosgreSQL database
I once took on responsibility for an Oracle database where its original developer documented every table and view and each of their columns in great detail. At first, I thought he was over-pedantic but after he showed me how to extract the comments from the data dictionary, I saw at once their usefullness: They made the database self-describing. That experience converted me and since PostgreSQL supports them using virtually identical syntax to Oracle, I was keen to carry this knowledge with me to my PostgreSQL work.

Database comments, like programming documentation generally, are only useful if they are:
* Clear
* Comprehensive
* Up-to-date

If the object definitions change but the comments are not updated, then they are downright misleading and worse than useless. Useful as database comments are, they are **not** a replacement for general application documention, version control or testing. They are just one component of good database development practice. I think of them like Python method and function [docstrings](https://en.wikipedia.org/wiki/Docstring). Like docstrings, they "live" with the objects that they describe so they can be queried at will. When familiarising myself with a new Python package, I like to check the function and method docstrings. If these dostrings are either absent or poorly written, I tend to become suspicious of the package quality generally. Likewise with databases, if the developer hasn't bothered to fill in the object comments, then I feel justified in doubting the overall quality of the database.


## Commenting user-defined functions
Schemas, tables, views, constraints and triggers are the backbone of any PostgreSQL database so I always try to ensure that I have documented them correctly using comments. I treat comments on tables and views and their columns as [metadata](https://en.wikipedia.org/wiki/Metadata), that is, data about about data. Metadata is very important so I try my best to make these comments adhere as closely as possible to the good comments criteria I have outlined above. However, it is not these objects that I wish to discuss here but rather user-defined functions (UDFs). If you create a UDF using the pgAdmin client, it provides a text input called unsurprisingly *Comment* where you can enter a textual description of the UDF. If you use the *psql* command line client, then, after creating the function, you can execute the *COMMENT ON <function_name(<argument types>);* statement to add the textual description. It is important to note that PL/pgSQL supports [function overloading](http://www.postgresqltutorial.com/plpgsql-function-overloading/). This is very useful but it means that you can have multiple instances of the same function name, qualified with the same schema name, provided that the they are distinguished by the number and/or types of their parameters. When it comes to commenting the different function overloads, you need to ensure that you are commenting the correct version. For example, the following two statements each add a comment to a different functions
 1. *COMMENT ON a_func(TEXT, TEXT) IS 'A pointless function';*
 2. *COMMENT ON a_func(TEXT, TEXT, TEXT) IS 'A pointless function'*
 The name *a_func* is over-loaded with two different functions that are distinguished by the number of parameters they take.
Coming from Oracle PL/SQL to PL/pgSQL, I was at first caught out by this behaviour because in PL/SQL, functions can only be overloaded if they are defined in packages. PL/pgSQL, however, does not support packages although they can be mimicked to some extent by using schemas. Anyway, always ensure that the the comment is applied to the correct overloaded version, otherwise the comments can be misleading.
  
## Using PL/pgSQL to comment UDFs
After trying to standardise my commenting for UDFs for some time with only limited success, I decided to try a different approach. What I was aiming for was an approach that I could use to add comments in a standardised format to UDFs with some default information filled where the entire comment was easily parsed. What I came up with, and what I want to describe here, is a PL/pgSQL function that uses its arguments to build a *COMMENT ON* command that it then executes. The comments themselves can only be stored as text by PostgreSQL but this function ensures that this text it creates can be parsed as JSONB where the comment constituent sections are stored using key names defined within the function body. I will explain the function in detail later but first, here is its definition:

```plpgsql
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
```

Now let's make this function **comment itself** by executing the following SQL:

```plpgsql
SELECT create_function_comment_statement('create_function_comment_statement', 
                                         ARRAY['TEXT', 'TEXT[]', 'TEXT', 'TEXT', 'TEXT'], 
                                         'Adds structured comments to user-defined functions so that the comments, although stored as text, can be returned as JSONB.', 
                                         $$SELECT * FROM create_function_comment_statement('get_table_count_for_schema', ARRAY['TEXT'])$$, 
                                         'This function executes dynamic SQL so it is set as *SECURITY INVOKER* and it should only be executed by users who can create functions.' ||
                                         'It checks that the comment text can be converted to JSONB and an error will arise if the it cannot be converted to JSONB' || 
                                         ' (line: *l_comment_as_jsonb := l_comment::JSONB;)*. Double quotes have special meaning in JSON so are disallowed in the input string arguments.' ||
                                         'To allow for single quotes in the example SQL, double dollar ($$) quoting is used to enclose the example SQL statement.'
                                         'Remember to include the schema name as art of the function name if it is not the default <public>. As PL/pgSQL allows function over-loading,' ||
                                         ' you need to ensure that the array of argument types exactly matches the function you wish to comment.');
```

### Notes on function *create_function_comment_statement*
* The function is created in the *public* schema
* The function takes the following arguments:
    1. The name of the function to comment, that is the *target function*. Give the name in the format    schema_name.function_name
    2. Text array of the parameters of the target function
    3. Sentence describing the purpose of the function
    4. An example of how the target function is called. This is enclosed in double dollar quotes ($$) to enclose the single quotes needed for text value arguments for the target function
    5. An optional descriptive note that if omitted, uses the empty string default.
* The *l_comment* variable is a template with curly braces and key names with place holders (%s) that make it JSON-conertible. The place-holders arefor passed in arguments passed and automatically assigned values for the date stamp and user.
* There is a second template defined by the variable *l_comment_statement* containing three place-holders:
    1. Function name
    2. Function arguments
    3. Comment text
* This template uses $qq$ ... $qq$$ to enclose the comment text. It cannot use '$$' because this is already taken to define the function itself.
* The values are FORMAT function is used to fill in the place-holders for both templates with the given target function parameter types array, *p_arg_types*, collapsed to a comma-separated string by the *ARRAY_TO_STRING* function call.
* I want to store the comment text in a format that can be converted to JSONB so before it is applied to the function, the line *l_comment_as_jsonb := l_comment::JSONB;* checks that the generated text can be converted to JSONB. If not, an unhandled exception is thrown.
* The full *COMMENT ON* command is now executed as dynamic SQL by calling *EXECUTE l_comment_statement;*.
* The full *COMMENT ON* text is returned.



```plpgsql
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
SELECT * FROM get_details_for_function('public', 'create_function_comment_statement');

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
SELECT get_text_as_jsonb('not "json"'::TEXT, 'COMMENT');

CREATE OR REPLACE FUNCTION get_function_details_for_schema(p_schema_name TEXT)
RETURNS TABLE(function_name TEXT, function_comment JSONB)
AS
$$                                         
DECLARE
  r_row RECORD;
BEGIN
  FOR r_row IN(SELECT 
                 n.nspname || '.' || p.proname function_name, 
                 get_text_as_jsonb(d.description, 'NON_JSONB_COMMENT') function_comment
               FROM
                 pg_proc p
                 INNER JOIN pg_namespace n ON n.oid = p.pronamespace
                   LEFT JOIN pg_description As d ON (d.objoid = p.oid )
               WHERE
                 n.nspname = p_schema_name)
  LOOP
    function_name := r_row.function_name;
    function_comment := r_row.function_comment;                                     
    RETURN NEXT;                                      
  END LOOP;
END;                                         
$$                                         
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
                                         
SELECT * FROM get_function_details_for_schema('ensembl');
                                         
SELECT 'abc'::JSONB; 
```
## Links
* If you're not familiar with this feature, it is worth taking some time to read the official documentation on them [here](https://www.postgresql.org/docs/10/static/sql-comment.html).
