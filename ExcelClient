
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

