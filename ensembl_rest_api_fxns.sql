CREATE SCHEMA ensembl;
CREATE ROLE genomics_reader LOGIN PASSWORD 'readonly';
GRANT CONNECT ON DATABASE genomics_apis TO genomics_reader;
GRANT USAGE ON SCHEMA ensembl TO genomics_reader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ensembl  TO genomics_reader;

CREATE OR REPLACE FUNCTION ensembl.get_ensembl_json(p_ext TEXT)
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
COMMENT ON FUNCTION ensembl.get_ensembl_json(TEXT) IS
$qq$
Purpose: Centralizes all calls to the Ensembl REST API, see: https://rest.ensembl.org/documentation. Individual PL/pgSQL functions use this
FUNCTION ensembl.to get specific JSONB return values. The second part of the URL, "p_ext" is expected to be fully formed with parameters inserted by the calling code.
Notes: Requires the "requests" module to be installed.
Example: SELECT * FROM ensembl.get_ensembl_json('/lookup/id/ENSG00000157764?expand=1');
$qq$;


CREATE OR REPLACE FUNCTION ensembl.get_details_for_id_as_json(p_identifier TEXT)
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
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_identifier);
  l_gene_details := ensembl.get_ensembl_json(l_rest_url_ext);
  RETURN l_gene_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_details_for_id_as_json(TEXT) IS
$qq$
Purpose: Find the species and database for a single identifier e.g. gene, transcript, protein using the Ensembl REST API.
Notes: Only accepts Ensembl identifiers and throws an error if the given identifier does not begin with "ENS".
Calls a stored Python FUNCTION ensembl.that does the actual REST API call. 
See Ensembl REST API documentation: https://rest.ensembl.org/documentation/info/lookup
Example: SELECT * FROM ensembl.get_details_for_id_as_json('ENSG00000157764');
$qq$;

CREATE OR REPLACE FUNCTION ensembl.get_details_for_symbol_as_json(p_symbol TEXT, p_species_name TEXT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/lookup/symbol/%s/%s?expand=1';
  l_symbol_details JSONB;
BEGIN
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_species_name, p_symbol);
  l_symbol_details := ensembl.get_ensembl_json(l_rest_url_ext);
  RETURN l_symbol_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_details_for_symbol_as_json(TEXT, TEXT) IS
$qq$
Purpose: Get details as JSONB from the Ensembl REST API for a given symbol, a gene name for example, and species name.
Notes: Takes the Latin name for "species",, "mus_musculus" or "homo_sapiens".
See documentation https://rest.ensembl.org/documentation/info/symbol_lookup
Example: SELECT * FROM ensembl.get_details_for_symbol_as_json('CD38', 'mus_musculus');
$qq$

CREATE OR REPLACE FUNCTION ensembl.get_features_for_genomic_location(p_species_name TEXT, p_chromosome_name TEXT, p_feature TEXT, p_start_pos BIGINT, p_end_pos BIGINT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/overlap/region/%s/%s:%s-%s?feature=%s';
  l_features_enum TEXT[] := ARRAY['band', 'gene', 'transcript', 'cds', 'exon', 'repeat', 'simple', 'misc', 'variation', 
                                 'somatic_variation', 'structural_variation', 'somatic_structural_variation', 'constrained', 
                                 'regulatory', 'motif', 'chipseq', 'array_probe'];
  l_symbol_details JSONB;
  l_is_feature_in_enum BOOLEAN;
BEGIN
  SELECT p_feature = ANY(l_features_enum) INTO l_is_feature_in_enum;
  IF NOT l_is_feature_in_enum THEN
    RAISE EXCEPTION 'Feature "%s" is not a recognized feature name. Recognized feature names: %s.', p_feature, ARRAY_TO_STRING(l_features_enum, E'\n');
  END IF;
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_species_name, p_chromosome_name, p_start_pos::TEXT, p_end_pos::TEXT, p_feature);
  l_symbol_details := ensembl.get_ensembl_json(l_rest_url_ext);
  RETURN l_symbol_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_features_for_genomic_location(TEXT, TEXT, TEXT, BIGINT, BIGINT) IS
$qq$
Purpose: Return all values for species, chromosome, feature and start stop position. 
Notes: The allowable feature names are checked and if the given feature name is not recognised, an exception is thrown.
The recognised ENUMs are represented as an array and the values were taken from this link: https://rest.ensembl.org/documentation/info/overlap_region
The returned JSON is an array of JSON objects and it can be very large.
Example: SELECT * FROM ensembl.get_features_for_genomic_location('homo_sapiens', 'X', 'variation', 136648193, 136660390);
This one will raise the exception: SELECT * FROM ensembl.get_features_for_genomic_location('homo_sapiens', 'X', 'variant', 136648193, 136660390);
$qq$

CREATE OR REPLACE FUNCTION ensembl.get_variant_table_for_gene_symbol(p_gene_symbol TEXT, p_species_name TEXT) 
RETURNS TABLE(ensembl_gene_id TEXT, gene_symbol TEXT, variant_id TEXT, consequence_type TEXT, variation_details JSONB)
AS
$$
DECLARE
  l_ensembl_gene_id TEXT;
  l_start BIGINT;
  l_end BIGINT;
  l_chromosome TEXT;
BEGIN
  SELECT
    gene_details->>'id',
    CAST(gene_details->>'start' AS BIGINT),
    CAST(gene_details->>'end' AS BIGINT),
    gene_details->>'seq_region_name'
      INTO l_ensembl_gene_id, l_start, l_end, l_chromosome
  FROM
    (SELECT ensembl.get_details_for_symbol_as_json(p_gene_symbol, p_species_name) gene_details) sq;
  RETURN QUERY
  SELECT
    l_ensembl_gene_id ensembl_gene_id,
    p_gene_symbol gene_symbol,
    (jsonb_array_elements(variations))->>'id' variation_id,
    (jsonb_array_elements(variations))->>'consequence_type' consequence_type,
    jsonb_array_elements(variations) variation_details
  FROM
    (SELECT ensembl.get_features_for_genomic_location(p_species_name, l_chromosome, 'variation', l_start, l_end) variations) sq;
    
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_variant_table_for_gene_symbol(TEXT, TEXT) IS
$qq$
Purpose: Return a table of all the variants (excludes structural variants) for a given gene symbol and species.
Notes: It uses the gene symbol to extract the gene object JSON from which it gets the chromosome and gene start and stop coordinates.
It then calls the FUNCTION "ensembl.get_features_for_genomic_location" passing in the required gene location arguments, extracts some values
from the JSON and returns a table.
An exception is raised if the gene symbol is not recognised.
Example: SELECT * FROM ensembl.get_variant_table_for_gene_symbol('CD38', 'homo_sapiens');
$qq$

CREATE OR REPLACE FUNCTION ensembl.get_variation_info_as_json(p_variation_id TEXT, p_species_name TEXT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/variation/%s/%s?content-type=application/json';
  l_variation_details JSONB;
BEGIN
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_species_name, p_variation_id);
  l_variation_details := ensembl.get_ensembl_json(l_rest_url_ext);
  RETURN l_variation_details;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_variation_info_as_json(TEXT, TEXT) IS
$qq$
Purpose: Return details for a given variation name and species name.
Example: SELECT * FROM ensembl.get_variation_info_as_json('rs7412', 'homo_sapiens');
$qq$

CREATE OR REPLACE FUNCTION ensembl.get_protein_ids_table_for_gene_ids(p_ensembl_gene_id TEXT)
RETURNS TABLE(ensembl_protein_id TEXT, is_canonical TEXT, translation_length INTEGER)
AS
$$
BEGIN
  RETURN QUERY
  SELECT *
  FROM
    (SELECT
      jsonb_array_elements(gene_details->'Transcript')->'Translation'->>'id' ensembl_protein_id,
      jsonb_array_elements(gene_details->'Transcript')->>'is_canonical' is_canonical,
      CAST(jsonb_array_elements(gene_details->'Transcript')->'Translation'->>'length' AS INTEGER) translation_length
    FROM
      (SELECT ensembl.get_details_for_id_as_json(p_ensembl_gene_id) gene_details) sqi) sqo
  WHERE
    sqo.ensembl_protein_id IS NOT NULL;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_protein_ids_table_for_gene_ids(TEXT) IS
$qq$
Purpose: Given an Ensembl gene ID, return a table listing all the Ensembl protein IDs for it giving the translation length
and a flag to inform if it is the canonical sequence for that gene.
Example: SELECT * FROM ensembl.get_protein_ids_table_for_gene_ids('ENSG00000004468');
$qq$

CREATE OR REPLACE FUNCTION ensembl.get_protein_sequence_as_text_for_gene_id(p_ensembl_gene_id TEXT)
RETURNS TEXT
AS
$$
DECLARE
  l_ensembl_protein_id TEXT;
  l_rest_url_ext TEXT := '/sequence/id/%s?content-type=application/json';
  l_sequence_as_json JSONB;
  l_sequence TEXT;
BEGIN
  SELECT ensembl_protein_id INTO l_ensembl_protein_id 
  FROM 
    ensembl.get_protein_ids_table_for_gene_ids(p_ensembl_gene_id);
  l_rest_url_ext := FORMAT(l_rest_url_ext, l_ensembl_protein_id);
  l_sequence_as_json := ensembl.get_ensembl_json(l_rest_url_ext);
  l_sequence := l_sequence_as_json->>'seq';
  RETURN l_sequence;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_protein_sequence_as_text_for_gene_id(TEXT) IS
$qq$
Purpose: Return the canonical protein sequence for a given Ensembl gene ID.
Example: SELECT ensembl.get_protein_sequence_as_text_for_gene_id('ENSG00000130203');
$qq$

CREATE OR REPLACE FUNCTION ensembl.get_vep_for_variation_id(p_variation_id TEXT, p_species_name TEXT)
RETURNS JSONB
AS
$$
DECLARE
 l_rest_url_ext TEXT := '/vep/%s/id/%s?content-type=application/json';
 l_vep_for_variation_id_json JSONB;
BEGIN
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_species_name, p_variation_id);
  l_vep_for_variation_id_json := ensembl.get_ensembl_json(l_rest_url_ext);
  RETURN l_vep_for_variation_id_json;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;
COMMENT ON FUNCTION ensembl.get_vep_for_variation_id(TEXT, TEXT) IS
$qq$
Purpose: Return the Variant Effect Predictor JSON for a given species name and variation ID.
Notes: The returned JSON is an array that contains some complex nested objects.
Exampl: SELECT * FROM ensembl.get_vep_for_variation_id('rs7412', 'homo_sapiens');
$qq$

-- There are a lot of functions here, this view is handy for viewing them.
CREATE OR REPLACE VIEW ensembl.vw_custom_functions AS
SELECT 
  p.proname AS funcname,  
  d.description, 
  n.nspname
FROM pg_proc p
  INNER JOIN pg_namespace n ON n.oid = p.pronamespace
    LEFT JOIN pg_description As d ON (d.objoid = p.oid )
WHERE
  nspname = 'ensembl'
ORDER BY 
  n.nspname;
COMMENT ON VIEW ensembl.vw_custom_functions IS 'Lists all custom functions in the schema "ensembl". Taken from http://www.postgresonline.com/journal/archives/215-Querying-table,-view,-column-and-function-descriptions.html.';

