CREATE OR REPLACE FUNCTION get_ensembl_json_for_entity(p_entity TEXT, p_ext TEXT)
RETURNS JSONB 
AS
$$
	import requests
	import json
    
	server = "https://rest.ensembl.org"
	response = requests.get(server + p_ext % p_entity, headers={ "Content-Type" : "application/json"})
	if not response.ok:
		response.raise_for_status()
 	return json.dumps(response.json())
$$
LANGUAGE 'plpythonu'
STABLE
SECURITY DEFINER;

COMMENT ON FUNCTION get_ensembl_json_for_entity(TEXT, TEXT) IS
$qq$
Purpose: Generalized function that takes an entity name (gene name, gene ID, SNP ID, etc) and the second part of the REST API URL that returns
a JSONB object. Centralizes all calls to the Ensembl REST API, see: https://rest.ensembl.org/documentation. Individual PL/pgSQL functions use this
function to get specific JSONB return values.
Example: SELECT * FROM get_ensembl_json_for_entity('ENSG00000157764', '/lookup/id/%s?expand=1');
$qq$;

CREATE OR REPLACE FUNCTION get_details_for_id_as_json(p_identifier TEXT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/lookup/id/%s?expand=1';
  l_gene_details JSONB;
BEGIN
  IF p_identifier !~ E'^ENS' THEN
    RAISE EXCEPTION 'The given identifier "%s" is invalid!', p_identifier;
  END IF;
  l_gene_details := get_ensembl_json_for_entity(p_identifier, l_rest_url_ext);
  RETURN l_gene_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

COMMENT ON FUNCTION get_details_for_id_as_json(TEXT) IS
$qq$
Purpose: Find the species and database for a single identifier e.g. gene, transcript, protein using the Ensembl REST API.
Notes: Only accepts Ensembl identifiers and throws an error if the given identifier does not begin with "ENS".
Calls a stored Python function that does the actual REST API call. 
See Ensembl REST API documentation: https://rest.ensembl.org/documentation/info/lookup
Example: SELECT * FROM get_details_for_id_as_json('ENSG00000157764');
$qq$;

-- ext = "/lookup/symbol/homo_sapiens/BRCA2?expand=1"
CREATE OR REPLACE FUNCTION get_details_for_symbol_as_json(p_symbol TEXT, p_species_name TEXT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/lookup/symbol/' || p_species_name || '/%s?expand=1';
  l_symbol_details JSONB;
BEGIN
  l_symbol_details := get_ensembl_json_for_entity(p_symbol, l_rest_url_ext);
  RETURN l_symbol_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION get_details_for_symbol_as_json(TEXT, TEXT) IS
$qq$
Purpose: Get details as JSONB from the Ensembl REST API for a given symbol, a gene name for example, and species name.
Notes: Takes the Latin name for "species",, "mus_musculus" or "homo_sapiens".
See documentation https://rest.ensembl.org/documentation/info/symbol_lookup
Example: SELECT * FROM get_details_for_symbol_as_json('CD38', 'mus_musculus');
$qq$

-- An over-loaded version of the function that takes no entity
-- Make this the main function and remove the previous one
CREATE OR REPLACE FUNCTION get_ensembl_json_for_entity(p_ext TEXT)
RETURNS JSONB 
AS
$$
	import requests
	import json
    
	server = "https://rest.ensembl.org"
	response = requests.get(server + p_ext, headers={ "Content-Type" : "application/json"})
	if not response.ok:
		response.raise_for_status()
 	return json.dumps(response.json())
$$
LANGUAGE 'plpythonu'
STABLE
SECURITY DEFINER;


CREATE OR REPLACE FUNCTION get_variants_from_position(p_species_name TEXT, p_chromosome_name TEXT, p_start_pos BIGINT, p_end_pos BIGINT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/overlap/region/%s/%s:%s-%s?feature=gene;feature=variation';
  l_symbol_details JSONB;
BEGIN
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_species_name, p_chromosome_name, p_start_pos::TEXT, p_end_pos::TEXT);
  l_symbol_details := get_ensembl_json_for_entity(l_rest_url_ext);
  RETURN l_symbol_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

SELECT * FROM get_variants_from_position('homo_sapiens', 'X', 136648193, 136660390);
