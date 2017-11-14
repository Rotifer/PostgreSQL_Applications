
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

Here is a simple VBA *Sub* that I wrote to test this module:

```vba
Option Explicit
' Module: modPgConnect
' Tests modPgConnect to ensure that Excel VBA can connect to the target PostgreSQL database.
Sub testConnection()
    Dim pgConn As ADODB.Connection
    Dim dbName As String: dbName = "Cancer_Cell_Line_Encyclopedia"
    Dim hostName As String: hostName = "<your host name>"
    Dim userName As String: userName = "shiny_reader"
    Dim portNum As Integer: portNum = 5432
    Dim pwd As String: pwd = "readonly"
    Dim dataRtvr As DataRetriever

    Set pgConn = modPgConnect.GetPgConnection(dbName, hostName, userName, portNum, pwd)
    MsgBox "All OK!"
    modPgConnect.ClosePgConnection pgConn
End Sub
```

The "OK!" message box tells me that my set-up is working and that I have all the necessary pieces in place to connect to the PostgreSQL database.

I can now check that I can call the PL/pgSQL stored functions defined above. I have defined VBA to call these functions in a **class**. I know that VBA's object-oriented feature set is incomplete but it is still worth using, especially for bigger projects. The class I have written is called *DataRetriever* and it contains just two methods:

```vba
Option Explicit

Private m_pgConn As ADODB.Connection
' Set the m_pgConn member.
Public Function Setup(pgConn As ADODB.Connection) As Boolean
    Set m_pgConn = pgConn
    Setup = True
End Function
' Return a recordset for a given gene name and metadata ID by calling the stored procedure "get_expr_vals_for_gene_name"
Public Function GetExprValsForGeneName(geneName As String, metadataID As Integer) As ADODB.Recordset
    Dim sprocName As String
    Dim cmd As ADODB.Command
    Dim param1 As ADODB.Parameter
    Dim param2 As ADODB.Parameter
    Dim rs As ADODB.Recordset
    Set cmd = New ADODB.Command
    sprocName = "get_expr_vals_for_gene_name"
    cmd.ActiveConnection = m_pgConn
    cmd.CommandType = adCmdStoredProc
    cmd.CommandText = sprocName
    Set param1 = cmd.CreateParameter("gene_name", adVarChar, adParamInput, Len(geneName), geneName)
    Set param2 = cmd.CreateParameter("metadata_id", adInteger, adParamInput, , metadataID)
    cmd.Parameters.Append param1
    cmd.Parameters.Append param2
    Set rs = cmd.Execute
    Set cmd = Nothing
    Set GetExprValsForGeneName = rs
End Function
' Called a PL/pgSQL stored function and convert the resulting table into an array and return it.
' To be used to populate a listbox in the application form.
Function GetMetadataIDs() As String()
    Dim rs As ADODB.Recordset
    Dim cmd As ADODB.Command
    Dim sprocName As String
    Dim metadataIDs() As String
    Dim rowNum As Integer: rowNum = 0
    
    sprocName = "get_metadata_ids"
    Set cmd = New ADODB.Command
    cmd.ActiveConnection = m_pgConn
    cmd.CommandType = adCmdStoredProc
    cmd.CommandText = sprocName
    Set rs = cmd.Execute
    rs.MoveFirst
    Do Until rs.EOF
        ReDim Preserve metadataIDs(rowNum)
        metadataIDs(rowNum) = CStr(rs.Fields(0))
        rowNum = rowNum + 1
        rs.MoveNext
    Loop
    rs.Close
    Set rs = Nothing
    Set cmd = Nothing
    GetMetadataIDs = metadataIDs
End Function
```

Ultimately, I want to use this class in a VBA form to write calues to sheets. Before I add the form, I use a plain module to create an instance of this class and test its methods. This module is simply called *testModDataRetriever*:

```vba
Option Explicit
' Module Name: testModDataRetriever
' Test that the methods defined in class *DataRetriever* work as expected.

' Write all the expression values for a hard-coded gene name to the active cell of the active sheet.
Private Sub GetExpressionDataForGene()
    Dim conn As ADODB.Connection
    Dim pwd As String
    Dim geneName As String: geneName = "CD38"
    Dim metadataID As Integer: metadataID = 1
    Dim dataRtvr As DataRetriever
    Dim rs As Recordset
    pwd = "readonly"
    Set conn = modPgConnect.GetPgConnection("Cancer_Cell_Line_Encyclopedia", "<host name>", "shiny_reader", 5432, pwd)
    Set dataRtvr = New DataRetriever
    dataRtvr.Setup conn
    Set rs = dataRtvr.GetExprValsForGeneName(geneName, metadataID)
    ActiveCell.CopyFromRecordset rs
    Set rs = Nothing
    modPgConnect.ClosePgConnection conn
    MsgBox "ok!"
End Sub

' Display the first metadata ID in a returned array in a message box.
Private Sub GetMetadataIDs()
    Dim conn As ADODB.Connection
    Dim pwd As String
    Dim dataRtvr As DataRetriever: Set dataRtvr = New DataRetriever
    Dim metadataIDs() As Integer
    
    pwd = "readonly"
    Set conn = modPgConnect.GetPgConnection("Cancer_Cell_Line_Encyclopedia", "192.168.49.15", "shiny_reader", 5432, pwd)
    dataRtvr.Setup conn
    metadataIDs = dataRtvr.GetMetadataIDs()
    modPgConnect.ClosePgConnection conn
    MsgBox metadataIDs(0)
End Sub
```

The Excel VBA *Range* object has a very convenient method called *CopyFromRecordset* that takes a *ADODB.Recordset* instance and writes its rows to the range. I use it here to dump the entire *Recordset* rows and columns into a sheet. It saves me having to loop over the recordset in a nested loop to write rows and columns to the target sheet.

I have now defined all the VBA and PL/pgSQL code that I need for a VBA form that will allow me to select a metadata ID from a listbox and a gene name from a textbox and then write the output data to a new Excel workbook that I can save where I wish. I'll also add VBA code to automatically generate pivot charts and pivot tables for the output data.
