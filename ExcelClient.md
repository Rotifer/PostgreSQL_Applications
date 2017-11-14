
# Excel Client

## Introduction

I have shown how to use PostgreSQL as a back-end for a Shiny application [here](https://github.com/Rotifer/PostgreSQL_Applications/blob/master/RShinyClient.md). Users often like an Excel application that allows them to download their data directly as a table that they can then manipulate at will in a familiar environment. I know Excel is less than ideal but its ubiquity and popularity make it hard to ignore. Also, I can re-use the same PL/pgSQL code I wrote for the Shiny app by calling it from Excel VBA. I know, VBA should have been retired years ago but this is an easy win for me because, thanks to the database code I have already written for the Shiny application, I really don't have to write much VBA at all. I think this is an oft-overlooked advantage of database procedures/function: they are written once but can be used in multiple applications.

## Steps in developing the Excel client
1. Install the psqlODBC client from [here](https://www.postgresql.org/ftp/odbc/versions/src/)
2. Set up a DSN as per instructions [here](http://www.postgresonline.com/journal/archives/24-Using-MS-Access-with-PostgreSQL.html).
3. In the VBA Editor add the required ADO reference as described [here](https://analysistabs.com/excel-vba/ado-sql-macros-connecting-database/)
4. Test connection to the database using VBA
5. Write a function calling the PL/pgSQL stored procedure to return a *Recordset*.
5. Write the *recordset data to a new sheet.
6. Programmatically create a pivot table and pivot chart.

## Extra PL/pgSQL Functions
I want to minimize the amount of work done in VBA. In the R client version, I defined two functions in the *server.R* file for retrieving data from the database. The first returns all the Ensembl gene IDs for a given gene while the second one uses this list to build the data frame by concatentaing the data frames for each Ensembl gene ID. For the Excel VBA version, I want to roll these two steps into one so I defined a new PL/pgSQL function that does this. It also gives me the opportunity to use the *RECORD* and the *RETURN NEXT* construct. Here it is:

```plpgsql
CREATE OR REPLACE FUNCTION get_expr_vals_for_gene_name(p_gene_name TEXT, p_metadata_id INTEGER)
RETURNS TABLE(ensembl_gene_id TEXT, gene_name TEXT, expr_val REAL, cell_line_name TEXT, cancer_name TEXT)
AS
$$
DECLARE
  l_ensembl_gene_ids TEXT[];
  l_ensembl_gene_id TEXT;
  r_row RECORD;
BEGIN
  SELECT ARRAY_AGG(f.ensembl_gene_id) INTO l_ensembl_gene_ids FROM get_ensembl_gene_ids_for_gene_name(p_gene_name) f;
  FOREACH l_ensembl_gene_id IN ARRAY l_ensembl_gene_ids
  LOOP
    FOR r_row IN
      (SELECT
        gev.ensembl_gene_id, 
        gev.gene_name, 
        gev.expr_val, 
        gev.cell_line_name, 
        gev.cancer_name
      FROM
        get_expr_vals_for_ensembl_gene_id_dataset(l_ensembl_gene_id,  p_metadata_id) gev)
    LOOP
      ensembl_gene_id := r_row.ensembl_gene_id;
      gene_name := r_row.gene_name;
      expr_val := r_row.expr_val;
      cell_line_name := r_row.cell_line_name;
      cancer_name := r_row.cancer_name;
      RETURN NEXT;
    END LOOP;
  END LOOP;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON  FUNCTION get_expr_vals_for_gene_name(p_gene_name TEXT, p_metadata_id INTEGER) IS
$qq$
Purpose: Return all records for a given gene name and metadata ID. Allows for gene names such as "MAL2@ that have multiple entries for
the same name. The outer loop iterates over all the Ensembl gene IDs found for the given gene name and the inner loop then
passes this Ensembl gene ID to the function "get_expr_vals_for_ensembl_gene_id_dataset". The output table is then populated with
the assignments from the RECORD and returned using the "RETURN NEXT" construct.
Example: SELECT ensembl_gene_id, gene_name, expr_val, cell_line_name, cancer_name FROM get_expr_vals_for_gene_name('mal2', 1);
$qq$
```

I also need a function to return all the metadata IDs so that they can be used in the form listbox for user selection. It might appear like over-kill to write a function for a task such as this that simply selects all the values for one column in a table. Why not use a simple SQL statement in the VBA code? My reasons for doing it this way are two-fold:

1. The account I am using has been set up so that it has no privileges on any tables, views or any other objects except stored functions.
2. I can re-use this same function in other clients so that if anything changes in the definition, I need only update the stored function. Here is this simple function:

```plpgsql
CREATE OR REPLACE FUNCTION get_metadata_ids()
RETURNS TABLE(metadata_id INTEGER)
AS
$$
BEGIN
  RETURN QUERY
  SELECT ccle_metadata_id FROM ccle_metadata;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION get_metadata_ids() IS
$qq$
Purpose: Get a list of all metadata IDs. To be used by accounts that can only execute stored PL/pgSQLO functions and cannot access tables or views.
Example: SELECT metadata_id FROM get_metadata_ids();
$qq$;
```

## Calling PL/pgSQL in VBA
In order for this to work I had to install the *pgODBC* library and reference the Active X Data Objects (ADO) library in the Visual Basic Editor (Tools->References). The first thing to verify is that I can connect to the database using same read-only account as I used in the R client. I have put the VBA code to create the connection, open and close it into a VBA module called *modPgConnect*:

```vba
Option Explicit
' modPgConnect: A module for encapsulating database connection, creation, opening and closing.
' Return an opened *Connection* object for the target database
Public Function GetPgConnection(dbName As String, server As String, userName As String, portNumber As Integer, pwd As String) As ADODB.Connection
    Dim connStr As String
    Dim pgConn As ADODB.Connection
    connStr = "Driver={PostgreSQL Unicode};Database=" & dbName & ";server=" & server & ";UID=" & userName & ";port=" & CStr(portNumber) & ";Pwd=" & pwd
    Set pgConn = New ADODB.Connection
    On Error GoTo ErrTrap
    pgConn.Open connStr
    Set GetPgConnection = pgConn
    Exit Function
ErrTrap:
    Err.Raise vbObjectError + 1000, "modPgConnect.GetPgConnection", Err.Description
End Function
' A function to close the *Connection* object and trap errors for an unopened or already closed *Connection*.
Public Function ClosePgConnection(pgConn As ADODB.Connection) As String
    On Error GoTo ErrTrap
    pgConn.Close
    ClosePgConnection = "Connection Closed!"
    Exit Function
ErrTrap:
    If Err.Description = "Object variable or With block variable not set" Then
        ClosePgConnection = "Database has not been opened"
        Exit Function
    ElseIf Err.Description = "Operation is not allowed when the object is closed." Then
        ClosePgConnection = "Database already closed"
        Exit Function
    End If
    Err.Raise vbObjectError + 1000, "modPgConnect.ClosePgConnection", Err.Description
End Function

```





