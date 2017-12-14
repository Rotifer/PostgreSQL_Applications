# Documenting PL/pgSQL Code

## Summary
Over the years I have written quite a few PostgreSQL user-defined functions (UDFs) mainly in PL/pgSQL but also, as the need arises, in PL/Python. If you do likewise, you might be interested in what I have written here where I try to describe an approach to writing standardised database comments to document these functions. Instead of issuing a series of *COMMENT ON FUNCTION* statements to do this, I have written one PL/pgSQL function to create the comment text and then execute the full *COMMENT ON* statement for me in a manner that creates a consistent comment format that can be converted to JSONB and then parsed to extract key information in a standardised and usable manner. Along the way, I demonstrate a few useful PL/pgSQL techniques to do things like build and execute dynamic SQL, parse JSONB and use PostgreSQL system catalogs and the ANSI SQL standard *INFORMATION_SCHEMA* views to retrieve information about UDFs. My aim is to use comments to make the database as self-documenting as possible. If you want to follow along with the examples here, you will need a reasonably good knowledge of SQL and PL/pgSQL and access to a fairly modern version of PostgreSQL, I have used version 9.6 for the examples here with pgAdmin 4 and *psql* as client programs


## The *COMMENT ON* command
Like Oracle, PostgreSQL supports the non-SQL standard *COMMENT ON* command to add custom documentation to pretty much any database object that the user can create. Such objects can be tables, views, columns, triggers, user-defined functions (UDFs) and so on. The only major relational database management system (RDBMS) that I have used that does not support this feature in some form is SQLite where I expect it is omitted to save space. Once written in PostgreSQL, comments can be retrieved from the ANSI SQL *INFORMATION_SCHEMA* or the system catalogs as I will demonstrate later.

### A note on PostgreSQL comments
You can generally only add comments to objects that you own. However, any user can see the comments that you add! The PostgreSQL documentation is very explicit on this point and states:
> There is presently no security mechanism for viewing comments: any user connected to a database can see all the comments 
> for objects in that database. For shared objects such as databases, roles, and tablespaces, comments are stored globally 
> so any user connected to any database in the cluster can see all the comments for shared objects. Therefore, don't put 
> security-critical information in comments.

## Why I use database object comments to document my PosgreSQL database
I once took on responsibility for an Oracle database where its original developer documented every table and view and each of their columns in great detail. At first, I thought he was over-pedantic but after he showed me how to extract the comments from the data dictionary, I saw at once their usefullness: They made the database self-describing. That experience converted me and since PostgreSQL supports them using virtually identical syntax to Oracle, I was keen to carry this knowledge with me to my PostgreSQL work.

Database comments, like programming documentation generally, are only useful if they are:
* Clear (easily read and understood)
* Comprehensive (fully describe what the object's role is)
* Consistent (all comments adhere to some standard in how they are written and the information they convey)
* Current (up-to-date)

These are my four C's. If the object definitions change but the comments are not updated, then they are downright misleading and worse than useless. Useful as database comments are, they are **not** a replacement for general application documention, version control or testing. They are just one component of good database development practice. I think of them like Python method and function [docstrings](https://en.wikipedia.org/wiki/Docstring). Like docstrings, they "live" with the objects that they describe so they can be queried at will. When familiarising myself with a new Python package, I like to check the function, class and method docstrings. If these dostrings are either absent or poorly written, I tend to become suspicious of the package quality generally. Likewise with databases, if the developer hasn't bothered to fill in the object comments, then I feel justified in doubting the overall quality of the database.


## Commenting user-defined functions
Schemas, tables, views, constraints and triggers are the backbone of any PostgreSQL database so I always try to ensure that I have documented them correctly using comments. I treat comments on tables and views and their columns as [metadata](https://en.wikipedia.org/wiki/Metadata), that is, data about about data. Metadata is very important so I try my best to make these comments adhere as closely as possible to the four C's criteria I have outlined above. However, it is not these objects that I wish to discuss here but rather user-defined functions (UDFs). If you create a UDF using the pgAdmin client, it provides a text input called unsurprisingly *Comment* where you can enter a textual description of the UDF. If you use the *psql* command line client, then, after creating the function, you can execute the *COMMENT ON <function_name(<argument types>);* statement to add the textual description. It is important to note that PL/pgSQL supports [function overloading](http://www.postgresqltutorial.com/plpgsql-function-overloading/). This is a very useful feature but it means that you can have multiple instances of the same function name, qualified with the same schema name, provided that the they are distinguished by the number and/or types of their parameters. When it comes to commenting the different function overloads, you need to ensure that you are commenting the correct version. For example, the following two statements each add a comment to a different functions

1. *COMMENT ON a_func(TEXT, TEXT) IS 'A pointless function';*
 2. *COMMENT ON a_func(TEXT, TEXT, TEXT) IS 'A pointless function'*

The name *a_func* is over-loaded with two different functions that are distinguished by the number of parameters they take.
Coming from Oracle PL/SQL to PL/pgSQL, I was at first caught out by this behaviour because in PL/SQL, functions can only be overloaded if they are defined in packages. PL/pgSQL, however, does not support packages although they can be mimicked to some extent by using schemas. Anyway, always ensure that the the comment is applied to the correct overloaded version, otherwise the comments can be misleading.
  
## Using PL/pgSQL to comment UDFs
After trying to standardise my commenting for UDFs for some time with only limited success, I decided to try a different approach. What I was aiming for was an approach that I could use to add comments in a standardised format to UDFs with some default information pre-filled and where the entire comment was easily parsed. What I came up with, and what I want to describe here, is a PL/pgSQL function that uses its arguments to build a *COMMENT ON* command that it then executes. The comments themselves can only be stored as text by PostgreSQL but this function ensures that this text that it creates can be parsed as JSONB where the comment constituent sections are stored using key names defined within the function body. I will explain the function in detail later but first, here is its definition:

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
                                         $$SELECT 1; -- Dummy example for this function$$, 
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
    1. The name of the function to comment, that is the *target function* given in the format *schema_name.function_name*
    2. Text array of the parameter types for the target function
    3. Sentence describing the purpose of the function
    4. An example of how the target function is called that is enclosed in double dollar quotes ($$) to enclose the single quotes needed for text value arguments for the target function
    5. An optional descriptive note that if omitted, uses the empty string default.
* The *l_comment* variable is a template with curly braces and key names with place holders (%s) that make it JSON-convertible. 
* The comment date and commeter ussername are assigned using PostgreSQL system information functions 
* There is a second template defined by the variable *l_comment_statement* containing three place-holders:
    1. Function name
    2. Function arguments
    3. Comment text
* This template uses $qq$ ... $qq$$ to enclose the comment text. It cannot use '$$' because this is already taken to define the function itself.
* The *FORMAT* function is used to fill in the place-holders for both templates with the given target function parameter types array, *p_arg_types*, collapsed to a comma-separated string by the *ARRAY_TO_STRING* function call.
* I want to store the comment text in a format that can be converted to JSONB so before it is applied to the function, the line *l_comment_as_jsonb := l_comment::JSONB;* checks that the generated text can be converted to JSONB. If not, an unhandled exception is thrown.
* The full *COMMENT ON* command is now executed as dynamic SQL by calling *EXECUTE l_comment_statement;*.
* The full *COMMENT ON* text is returned.
* This function is defined as *SECURITY INVOKER* because it is only intended to be use by users who can create functions. Any dunction that can execute dynamic SQL should be treated with caution to ensure that users do not deleiverately or inadvertantly build and execute a destructive SQL statement. 

## Demonstrating the commenting function
Now that I have created the function, I am going to create a useless PL/pgSQL function to show how it can be aplied and how the added comment can be retrieved and parsed.

Here is a function that returns the base table count, that is views are excluded, for the given schema:

```plpgsql
CREATE OR REPLACE FUNCTION get_table_count_for_schema(p_schema_name TEXT)
RETURNS OID
AS
$$
DECLARE
  l_table_count INTEGER;
BEGIN
  SELECT INTO l_table_count
    COUNT(table_name)
  FROM
    information_schema.tables
  WHERE
    table_schema = p_schema_name
    AND
      table_type = 'BASE TABLE';
  RETURN l_table_count;
END;
$$
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER;
```
I've created it in the default *public* schema. Now that it is created, I'll use my UDF commenter function to add the comment like so:
```sql
SELECT create_function_comment_statement('get_table_count_for_schema',
                                        ARRAY['TEXT'],
                                        'Return the base table count for a given schema name.',
                                        $$SELECT * FROM get_table_count_for_schema('pg_catalog');$$,
                                        'This is a demo function only to show how the function ' ||                    'create_function_comment_statement ' ||
                                        'can be used to add documentation comments to a function. ' ||
                                         'Use command DROP FUNCTION get_table_count_for_schema(TEXT) to remove it.');

```

When I execute the SQL above, the comment is created and the full *COMMENT ON* command text is returned.

### Note
**Since the commenting function tests that the comment text can be converted to JSONB, embedded double quotes are not allowed. This is a JSON rule. However, embedded new lines also cause a JSONB conversion error and I am unsure why this happens because embedded new line characters are allowed in standard JSON**


## Extracting the comments
The code so far may seem like more effort than it is worth but, now that I have added the comments, I will show how they can be extracted and parsed.

To demonstrate this, here is a UDF to extract a table of information for a function in a schema. I'll describe how it works later.

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
```

### Notes on function *get_details_for_function*
* Created here in the public schema but it could be qualified by a schema name to create it elsewhere
* The arguments are the schema and function name
* The return type is *TABLE* with four columns. The fourth column is of type JSONB and contains the comment.
* Because of function overloading:
    1. It may return more than one row
    2. The function OID is needed to uniquely identify each version of the overloaded function
* The line *d.description::JSONB function_comment* does a text to JSONB conversion of the comment text. If the text is unconvertible, an unhandled error will be raised.
* It uses three system catalogs:
    1. pg_proc
    2. pg_namespace
    3. pg_description

Let's add documentation using my commenter function as shown before:

```sql
SELECT create_function_comment_statement('get_details_for_function', 
                                         ARRAY['TEXT', 'TEXT'], 
                                         'Returns a table of information for a given schema name  and function name.', 
                                         $$SELECT * FROM get_details_for_function('public', 'create_function_comment_statement');$$, 
                                         'Because PL/pgSQL supports function over-loading, this function can return more than one row' || 
                                         'for a given schema name and function name. The actual comment is returned as JSONB in the column named <function_comment>.');

```

To see the function in action, I have written the following SQL statement:

```sql
SELECT
  function_name,
  function_parameters, 
  function_oid,
  function_comment->>'Purpose',
  function_comment->>'Example',
  function_comment->>'Notes',
  function_comment->>'Commenter_Username',
  function_comment->>'Comment_Date'
FROM
  (SELECT *
   FROM
     get_details_for_function('public', 'get_table_count_for_schema')) func_details;
```
Note the call to function *get_details_for_function* in the inner query named *func_details*! The output here is a single row where the comment for the function *get_table_count_for_schema* defined earlier is parsed using the JSONB *->>* operator to extract the comment components.

## Extracting comments for all UDFs in a schema 
The function *get_details_for_function* can extract details for one function and its over-loaded versions. On its own, this is not so useful. Because PL/pgSQL, unlike Oracle PL/SQL, does not support packages, the recommended work-around is to use schemas instead to group related functions. I put all general purpose UDFs such as *create_function_comment_statement* into the *public* schema and then put specialised UDFs into groups in their own schemas. I would therefore like to be able to extract the documentation for all UDFs in a given schema. I would also like to be able to cater for comments that were added to UDFs in this schema before I started using the function *create_function_comment_statement*. I can still extract them as JSONB but first I need to remove double quotes and new lines (if present) and provide a key for the JSONB.

Here is a function that performs these task:

```plpgsql
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
```
This function takes text and an arbitrary key value as input and replaces double quotes with asterisks and embedded new lines with blanks and then returns JSONB as a key-value pair using the dummy value as the key. Note how it uses exception handling: If the input text can be converted directly to JSONB, the converted value is returned directly and the exception isn't triggered, if the conversion fails, the code exception block runs and does the JSONB conversion and returns the text as JSONB.

Once again, let's add documentation using the commenter function:

```sql
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
  
```

Now using this helper function, I can retrieve all the comments for all UDFs in a given schema:

```plpgsql
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
```
As in an earlier example, this function once again uses system catalogs *pg_proc*, *pg_namespace* and *pg_description* to extract the required information. The comment itself is passed to the UDF named *get_text_as_jsonb* that I defined earlier and it coerces the comment text into JSONB.

Keeping up the good habit, let's add a comment in the desired format:

```sql
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
```
As I mentioned earlier, PostgreSQL schemas provide a convenient mechanism for grouping objects by their functionality; they are in effect namespaces. I typically have multiple schemas that contain only UDFs so to make them more manageable, I create a view in each schema that I call *vw_udf_documentation* that uses the above function to extract the function comments. Here is the view definition for the *public* schema:

```
CREATE OR REPLACE VIEW public.vw_udf_documentation AS                                        
SELECT
  function_oid,
  function_name,
  function_comment,
  function_comment->>'Purpose' purpose,
  function_comment->>'Example' example_call,
  function_comment->>'Notes' notes,
  function_comment->>'Commenter_Username' comment_added_by,
  function_comment->>'Comment_Date' comment_date
FROM 
  get_function_details_for_schema('public', 'NON_STANDARD_COMMENT');                                        
COMMENT ON VIEW public.vw_udf_documentation IS 'Uses the UDF get_function_details_for_schema to extract documentation from UDF comments in the schema public.';                                       
```

Having this view in each schema:
* Allows me to see all the UDFs defined in that schema
* Provides me with the OID values for each function (to be used as arguments to built-in PostgreSQL functions)
* Highlights functions that have non-standard or NULL comments - it does handle NULL comments
* Helps other users quickly navigate the database

## Conclusions
I now use this approach to document my UDFs and have migrated all my old comments into this format. Readers may have their own requirements and conventions but I think the code examples I have given here could help. Documenting code may not be the most exciting task in the world but trying to debug and understand undocumented or poorly documented code is even less fun so it is definitely worth the effort to do it properly. I hope that the and tools and approach that I have described here help at least some readers in their efforts.

## Links
* If you're not familiar with this feature, it is worth taking some time to read the official documentation on them [here](https://www.postgresql.org/docs/9.6/static/sql-comment.html).
* Wikipedia entry on [INFORMATION_SCHEMA](https://en.wikipedia.org/wiki/Information_schema).
* PostgreSQL [system information functions] (https://www.postgresql.org/docs/9.6/static/functions-info.html)
* The System Catalog Information Functions given in the [documentation](https://www.postgresql.org/docs/9.6/static/functions-info.html) are well worth perusing; There are some very useful ones for extracting information about functions generally, for example, the return type, the definitions, the paramaters and so forth.
* Some good general advice in [Make Your Relational Database Self-Documenting](https://glennstreet.net/2013/08/24/make-your-relational-database-self-documenting-2/).
* Description of SQL Server extended properties (comments) [Towards the Self-Documenting SQL Server Database](https://www.red-gate.com/simple-talk/sql/sql-tools/towards-the-self-documenting-sql-server-database/)


## Contact nformation
Michael Maguire  
Written: 2017-12-11  
Email: mick@javascript-spreadsheet-programming.com  
Twitter: https://twitter.com/michaelfmaguir1  
