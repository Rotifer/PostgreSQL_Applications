# PostgreSQLShiny

## Summary
Shiny Apps with PostgreSQL back-end.


This repository is a record of the actions taken to create a Shiny application to view and visualize Cancer Cell Line Enncyclopedia RNA-seq data. The data sources are [here](https://www.ebi.ac.uk/gxa/experiments/E-MTAB-2770/Downloads). 

To Do: Add a more detailed data description.

## Downloading the source TSV file, loading it into PostgreSQL and parsing it into tables

### Downloading

```
$ wget https://www.ebi.ac.uk/gxa/experiments-content/E-MTAB-2770/resources/ExperimentDownloadSupplier.RnaSeqBaseline/tpms.tsv
```

### Moving the file contents to a PostgreSQL DB

First, log in to *psql*. Assumes the port is 5432 and the password is set in the *.pgpass*.

```
$ psql -d Cancer_Cell_Line_Encyclopedia -h <host name> -U <user name>
```

The downloaded file is tab-delimited with a lot of columns (956 to be precise). I do the actual  parsing in PostgreSQL itself so the first step is to load the entire file intowhat I refer to as atransfer table. The table definition is:

```sql
CREATE UNLOGGED TABLE transit_tmp(
    data_row TEXT
);
COMMENT ON TABLE transit_tmp
    IS 'Used to store unprocessed data before it is munged and moved to permanent tables.';
```

This table has only a single column and I have deliberately omitted the primary key. Since the data here is transitory, I've defined it as an unlooged table which makes it slightly more performant. I can do this safely because I am not worried about losing its data in the event of a database crash.

I use a single *plsql \COPY* command to load the data into the *transit_tmp* table:

```
Cancer_Cell_Line_Encyclopedia=> \COPY transit_tmp FROM '<path to tpms.tsv file>' DELIMITER E'\b';
```

The delimiter '\b' was chosen because it does **not** exist in the file and, therefore, each full line is pushed into a single column called *data_row* in the target table *transit_tmp*. I tried using a Python's *psycopg2* to do this loading but it was very slow (>10 minutes).

### Parsing the loaded data

Now for the fun part. I want to:

1. Store the expression values, from column three onwards, as PostgreSQL arrays.
2. Record the metadata stored in the first four lines of the source file and prefixed with '#'.
3. Turn the fifth line that contains the column headings for the expression values into rows where each row containsthe cell line name, the cancer name and the index number of the column that will be used later to retrieve the expression values from the array. Remember that PostgreSQL arrays are 1-based! The first two column names of the input line are discarded from the table generated here because they refer to the genes. 

Here are the table definitions (see the stored comments for table descriptions):

```sql
CREATE TABLE ccle_metadata(
  ccle_metadata_id SERIAL PRIMARY KEY,
  metadata TEXT);
COMMENT ON TABLE ccle_metadata IS 'Contains the metadata headings (lines with "#" prefix) for all CCLE data loaded into this database. Each metadata line is separated by a tab';

CREATE TABLE cell_line_cancer_type_idx_map(
  cell_line_cancer_type_idx_map_id SERIAL PRIMARY KEY,
  cell_line_name TEXT,
  cancer_name TEXT,
  expr_val_idx INTEGER,
  ccle_metadata_id INTEGER REFERENCES ccle_metadata(ccle_metadata_id));
COMMENT ON TABLE cell_line_cancer_type_idx_map IS 'Stores the cell line name and the cancer type it relates to with the index position (1-based) for the corresponding expression values stored in table "gene_expression_values".';

CREATE TABLE gene_expression_values(
  gene_expression_values_id SERIAL PRIMARY KEY,
  ensembl_gene_id TEXT,
  gene_name TEXT,
  expr_vals TEXT[],
  ccle_metadata_id INTEGER REFERENCES ccle_metadata(ccle_metadata_id)
);
COMMENT ON TABLE gene_expression_values IS 'Stores gene identifiers with their corresponding expression values that are stored as an array.';

```

Now that the tables are created, I will populate them using plain SQL. This SQL depends heavily on array manipulation. Remember that the input data is tab-separated so you will see a lot of string splitting using the the tab character (defined as E'\t' in the SQL statements).

**Storing the metadata**

```sql
INSERT INTO ccle_metadata(metadata)
SELECT
  ARRAY_TO_STRING(ARRAY_AGG(data_row), E'\t')
FROM
  transit_tmp
WHERE
  data_row ~ '^#';
```

**Storing the cell line column names as rows**

```sql
INSERT INTO cell_line_cancer_type_idx_map(cell_line_name, cancer_name, expr_val_idx, ccle_metadata_id)
SELECT
  cell_line_name,
  cancer_name,
  CAST(ROW_NUMBER() OVER() AS INTEGER) expr_val_idx,
  1::INTEGER
FROM
  (SELECT
    (STRING_TO_ARRAY(UNNEST(colnames), ','))[1] cell_line_name,
    ARRAY_TO_STRING((STRING_TO_ARRAY(UNNEST(colnames), ','))[2:3], ',') cancer_name
  FROM
    (SELECT
      STRING_TO_ARRAY(data_row, E'\t') colnames
    FROM
      transit_tmp
    OFFSET 4 LIMIT 1) sqi
  OFFSET 2) sqo;
```

**Storing the gene expression values**

```sql
INSERT INTO gene_expression_values(ensembl_gene_id, gene_name, expr_vals, ccle_metadata_id)
SELECT
  (STRING_TO_ARRAY(data_row, E'\t'))[1] ensembl_gene_id,
  (STRING_TO_ARRAY(data_row, E'\t'))[2] gene_name,
  (STRING_TO_ARRAY(data_row, E'\t'))[3:936] expr_vals,
  1::INTEGER
FROM
  (SELECT
    data_row
  FROM
    transit_tmp
  WHERE
    data_row ~ '^ENSG') sq;
```

**Extraccting the data in aformat suitable for R**

Now that the data is structured in tables, I need a way to extract data into a form that is usable in R. This requires turning the PostgreSQL arrays into rows and matching these rows with the cancer and cell line types. I am interested in returning the expression data as a table for a given gene name. The example given here contains data for only one data set, TPMS, but I want to allow for storage of other data types so I need to filter so as to only return the expression data for a one data set regardless of how many I have stored in the database. The value for *ccle_metadata_id* from the *ccle_metadata* table has been posted to the two other data tables as a foreign key for this very purpose. To return the table, I have defined a PL/pgSQL function that takes two parameters: the gene name and the *ccle_metadata_id*. Before I define this function, I need an additional helper function whose purpose is to determine if the expression values are numeric. Some of the data points in the input file are *null*. When I split on tabs to create the arrays, these are represented as empty strings. And no, empty strings are not NULL despite what Oracle thinks. I want to ensure that these empty strings are returned as true NULLs in the output table. The following Boolean returning function does the trick:

```plpgsql
CREATE OR REPLACE FUNCTION isnumeric(text) RETURNS BOOLEAN AS $$
DECLARE x NUMERIC;
BEGIN
    x = $1::NUMERIC;
    RETURN TRUE;
EXCEPTION WHEN others THEN
    RETURN FALSE;
END;
$$
STRICT
LANGUAGE plpgsql IMMUTABLE;
COMMENT ON FUNCTION isnumeric(text) IS $qq$ Purpose: Check if the given argument is a number. Used to check substrings created by splitting strings into arrays. Copied verbatim from this source: http://stackoverflow.com/questions/16195986/isnumeric-with-postgresql. $qq$;
```

Now I can define the main function that will return a **table** of expression values for all cell lines and cancer types for a given gene name and metadata ID. Here it is:

```plpgsql
CREATE OR REPLACE FUNCTION get_expression_values_for_genename_dataset(p_gene_name TEXT, p_ccle_metadata_id INTEGER)
RETURNS TABLE(ensembl_gene_id TEXT, gene_name TEXT, expr_val REAL, cell_line_name TEXT, cancer_name TEXT)
AS
$$
BEGIN
  RETURN QUERY
  SELECT
    sqo.ensembl_gene_id,
    sqo.gene_name,
    CASE 
      WHEN isnumeric(sqo.expr_val) THEN CAST(sqo.expr_val AS REAL)
      ELSE NULL
    END expr_val,
    clctim.cell_line_name,
  clctim.cancer_name
  FROM
    (SELECT
      sqi.ensembl_gene_id,
      sqi.gene_name,
      sqi.expr_val,
      ROW_NUMBER() OVER() expr_val_idx
    FROM
      (SELECT
        gev.ensembl_gene_id,
        gev.gene_name,
        UNNEST(gev.expr_vals) expr_val
      FROM
        gene_expression_values gev
      WHERE
        gev.gene_name = p_gene_name) sqi) sqo
    JOIN
      cell_line_cancer_type_idx_map clctim ON sqo.expr_val_idx = clctim.expr_val_idx
  WHERE
    clctim.ccle_metadata_id = p_ccle_metadata_id;
END;
$$
LANGUAGE plpgsql SECURITY DEFINER STABLE;
COMMENT ON FUNCTION get_expression_values_for_genename_dataset(TEXT, INTEGER) IS
$qq$
Summary: Returns a table of CCLE expression values and their corresponding gene, cell line name and cancer type values for a given gene name
and metadata ID.
Example: SELECT * FROM get_expression_values_for_genename_dataset('CD38', 1);
$qq$
```

**Extracting the data into a TSV file using the PL/pgSQL function**

```
psql -h <host name> -d Cancer_Cell_Line_Encyclopedia  -U <user name> -A -F $'\t' -X -t -c "SELECT * FROM get_expression_values_for_genename_dataset('CLEC2D', 1)" -o clec2d_ccle_expression.tsv
```

I will come back to this section and add explanatory notes for this relatively complex function. This function can now be called in R to return a data frame.
