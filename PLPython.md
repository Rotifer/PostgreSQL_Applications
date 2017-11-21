# Writing Custom PostgreSQL Functions in PL/Python

One thing I particularly like about PostgreSQL is the ability to write functions in languages other than PL/pgSQL. One of these is Python and I like it because I can use its extensive libraries to do things that are difficult or impossible with Pl/pgSQL. If I am doing things that are easy in SQL steps, then I tend to use PL/pgSQL to wrap the SQL statements into a handy function. However, sometimes, I want to call do something like call a REST API and manipulate the returned JSON or I need a specialized Python module to perform a certain task.

## Examples

For the examples given here, I added the *plpythonu* extension in a test database. I did this by selecting *extensions* in the pgAdmin objects tree and then riight-clicked to bring up the dialog to add in the extension. For this example I used my system Python 2.7 and installed *pip* by following the instructions [here](https://pip.readthedocs.io/en/stable/installing/). I then used *pip* to install two modules that are required in the examples: *requests* for the REST API calling function and *biopython* for the function to return the molecular weight for a given biomolecule sequence (DNA, RNA or protein).

1. Calculate the molecular weight for a given bio-molecule sequence

```plpythonu
CREATE OR REPLACE FUNCTION get_mol_wt(p_sequence TEXT, p_alphabet TEXT, p_double_stranded BOOLEAN DEFAULT FALSE, 
                                      p_circular BOOLEAN DEFAULT FALSE, p_monoisotopic BOOLEAN DEFAULT FALSE) 
RETURNS REAL 
AS
$$
    import Bio.SeqUtils
    return Bio.SeqUtils.molecular_weight(Bio.SeqUtils.Seq(p_sequence), p_alphabet, p_double_stranded, p_circular, p_monoisotopic)
$$
LANGUAGE 'plpythonu'
IMMUTABLE
SECURITY DEFINER;
COMMENT ON FUNCTION get_mol_wt(TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN) IS
$qq$
Purpose: Return the molecular weight for a given bio-molecule sequence. 
See the section on method "molecular_weight" in http://biopython.org/DIST/docs/api/Bio.SeqUtils-module.html for full details.
Example: SELECT get_mol_wt('ACG', 'DNA', TRUE);
$qq$;
```

2. Get details for a given gene identifier as JSONB by calling a REST API

```plpythonu
CREATE OR REPLACE FUNCTION get_ensembl_json_for_id(p_ensembl_gene_id TEXT)
RETURNS JSONB
AS
$$
	import requests
	import json
    
	server = "https://rest.ensembl.org"
	ext = "/lookup/id/%s?expand=1" % p_ensembl_gene_id
	response = requests.get(server+ext, headers={ "Content-Type" : "application/json"})
	if not response.ok:
		response.raise_for_status()
 	return json.dumps(response.json())
$$
LANGUAGE 'plpythonu'
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION get_ensembl_json_for_id(TEXT) IS
$qq$
Purpose: Return a JSONB object for a given Ensembl gene ID by calling the Ensembl REST API.
Example:
SELECT *
FROM
  jsonb_each_text(get_ensembl_json_for_id('ENSG00000157764'))
Note: This function has been declared as "STABLE" rather than "IMMUTABLE" because the data served from the REST API can change over time as the Ensembl resource is updated.
$qq$;
```

I now have two useful functions that use Python to extend the functionality of my database. The first example that calculates the bio-molecule molecular weight provides me with a simple function to calculate molecular weights for the three common types of biomolecules: RNA, DNA and protein. If I had to code this from scratch in PL/pgSQL, it would not be a trivial task. By off-loading it to a method call written in a widely used and tested Python module, I can implement it in just a feew lines of Python code and be confident that the Python code is well-tested and will not accept invalid sequences. The second function shows how easy it is, thanks to the excellent *requests* module, to to perform a REST API call from inside the database. Once I have the JSONB, I can process it further in either SQL or PL/pgSQL using PostgreSQL's excellent JSON functionality. 

The main disadvantage of using a language extension such as PL/Python is that it introduces an external dependency. PL/pgSQL comes installed already on every PostgreSQL database. When I use a language like PL/Python, I have to ensure thast Python is installed and available to the PostgreSQL server.

