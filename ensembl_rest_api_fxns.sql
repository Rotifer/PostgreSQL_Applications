-- Contains functions that use the Ensembl REST API (https://rest.ensembl.org/).
-- Relies on the plpythonu extension and the Python "requests" module to do the REST API calls.

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


CREATE OR REPLACE FUNCTION ensembl.get_features_for_genomic_location(p_species_name TEXT, 
								     p_chromosome_name TEXT, 
								     p_feature TEXT, 
								     p_start_pos BIGINT, 
								     p_end_pos BIGINT)
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

CREATE OR REPLACE FUNCTION ensembl.get_gene_id_for_species_name(p_species_name TEXT, p_gene_name TEXT)
RETURNS TEXT
AS
$$
DECLARE
  l_gene_details JSONB;
  l_gene_id TEXT;
BEGIN
  l_gene_details := ensembl.get_details_for_symbol_as_json(p_gene_name, p_species_name);
  SELECT l_gene_details->>'id' INTO l_gene_id;
  RETURN l_gene_id;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_fastas_for_species_gene(p_species_names TEXT[], p_gene_name TEXT)
RETURNS TEXT
AS
$$
DECLARE
  l_species_name TEXT;
  l_ensembl_gene_id TEXT;
  l_gene_aa_sequence TEXT;
  l_gene_sequence_fasta TEXT := '';
BEGIN
  FOREACH l_species_name IN ARRAY p_species_names
  LOOP
    l_ensembl_gene_id := ensembl.get_gene_id_for_species_name(l_species_name, p_gene_name);
    l_gene_aa_sequence := ensembl.get_protein_sequence_as_text_for_gene_id(l_ensembl_gene_id);
    l_gene_sequence_fasta := l_gene_sequence_fasta || '>' || p_gene_name || '|' || l_species_name || E'\n'
                               || l_gene_aa_sequence || E'\n';
  END LOOP;
  RETURN TRIM(l_gene_sequence_fasta);
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_xref_info_for_ensembl_id(p_ensembl_id TEXT)
RETURNS JSONB
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/xrefs/id/%s?content-type=application/json';
  l_xref_info JSONB;
BEGIN
  l_rest_url_ext := FORMAT(l_rest_url_ext, p_ensembl_id);
  l_xref_info := ensembl.get_ensembl_json(l_rest_url_ext);
  RETURN l_xref_info;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_xref_table_for_ensembl_id(p_ensembl_id TEXT)
RETURNS TABLE(primary_id TEXT, dbname TEXT)
AS
$$
DECLARE
  l_rest_url_ext TEXT := '/xrefs/id/%s?content-type=application/json';
  l_xref_info JSONB := ensembl.get_xref_info_for_ensembl_id(p_ensembl_id);
BEGIN
  RETURN QUERY
  SELECT
    xref_row->>'primary_id',
    xref_row->>'dbname'
  FROM
    (SELECT
       jsonb_array_elements(l_xref_info) xref_row) xref;
END;
$$
LANGUAGE plpgsql
STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_uniprot_id_for_ensembl_gene_id(p_ensembl_gene_id TEXT)
RETURNS TEXT
AS
$$
DECLARE
  l_uniprot_id TEXT;
  l_dbname TEXT := 'Uniprot_gn';
BEGIN
  SELECT 
    primary_id INTO STRICT l_uniprot_id 
  FROM 
    ensembl.get_xref_table_for_ensembl_id(p_ensembl_gene_id)
  WHERE 
    dbname = l_dbname;
  RETURN l_uniprot_id;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_fasta_for_gene_from_uniprot(p_uniprot_id TEXT)
RETURNS TEXT
AS
$$
	import requests
    
	url = 'http://www.uniprot.org/uniprot/%s.fasta' % p_uniprot_id
	response = requests.get(url, headers={ "Content-Type" : "application/text"})
	if not response.ok:
		response.raise_for_status()
 	return response.text
$$
LANGUAGE 'plpythonu'
STABLE
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_uniprot_fastas_for_species_gene(p_species_names TEXT[], p_gene_name TEXT)
RETURNS TEXT
AS
$$
DECLARE
  l_species_name TEXT;
  l_ensembl_gene_id TEXT;
  l_uniprot_ids TEXT[];
  l_uniprot_id TEXT;
  l_uniprot_fasta TEXT;
  l_uniprot_fastas TEXT := '';
BEGIN
  FOREACH l_species_name IN ARRAY p_species_names
  LOOP
    l_ensembl_gene_id := ensembl.get_gene_id_for_species_name(l_species_name, p_gene_name);
    l_uniprot_ids := ensembl.get_uniprot_id_array_for_ensembl_gene_id(l_ensembl_gene_id);
    FOREACH l_uniprot_id IN ARRAY l_uniprot_ids
    LOOP
      l_uniprot_fasta := ensembl.get_fasta_for_gene_from_uniprot(l_uniprot_id);
      l_uniprot_fastas := l_uniprot_fastas || l_uniprot_fasta;
    END LOOP;
  END LOOP;
  RETURN TRIM(l_uniprot_fastas);
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

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

CREATE OR REPLACE FUNCTION ensembl.get_uniprot_id_array_for_ensembl_gene_id(p_ensembl_gene_id TEXT)
RETURNS TEXT[]
AS
$$
DECLARE
  l_uniprot_ids TEXT[];
  l_dbname TEXT := 'Uniprot_gn';
BEGIN
  SELECT 
    ARRAY_AGG(primary_id) INTO l_uniprot_ids
  FROM 
    ensembl.get_xref_table_for_ensembl_id(p_ensembl_gene_id)
  WHERE 
    dbname = l_dbname;
  RETURN l_uniprot_ids;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensembl.get_details_for_id_array_as_json(p_ids TEXT[])
RETURNS JSONB[]
AS
$$
DECLARE
  l_id TEXT;
  l_id_details JSONB;
  l_details_all_ids JSONB[] := ARRAY_FILL('{}'::JSONB, ARRAY[ARRAY_LENGTH(p_ids, 1)]);
  l_loop_counter INTEGER := 1;
  l_err_entry JSONB;
BEGIN
  FOREACH l_id IN ARRAY p_ids
  LOOP
    BEGIN
      l_id_details := ensembl.get_details_for_id_as_json(l_id);
	  l_details_all_ids[l_loop_counter] := l_id_details;
	  l_loop_counter := l_loop_counter + 1;
	EXCEPTION WHEN OTHERS THEN
	  l_err_entry := (FORMAT('{"ERROR INPUT ID": "%s"}', l_id))::JSONB;
	  l_details_all_ids[l_loop_counter] := l_err_entry;
	  l_loop_counter := l_loop_counter + 1;
	END;
  PERFORM PG_SLEEP(1);
  END LOOP;
  RETURN l_details_all_ids;
END;
$$
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER;

-- Create a view to display comments in parsed table
CREATE OR REPLACE VIEW ensembl.vw_udf_documentation AS                                        
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
  get_function_details_for_schema('ensembl', 'NON_STANDARD_COMMENT');                                        
COMMENT ON VIEW ensembl.vw_udf_documentation IS 'Uses the UDF get_function_details_for_schema to extract documentation from UDF comments in the schema *ensembl*.';

-- Add documentation comments to all UDFs in this schema

SELECT create_function_comment_statement(
  'ensembl.get_features_for_genomic_location',
  ARRAY['TEXT', 'TEXT', 'TEXT', 'BIGINT', 'BIGINT'],
  'Return a JSONB array of all values for the given species, chromosome and feature type contained within the given and start and stop coordinates.',
  $$SELECT * FROM ensembl.get_features_for_genomic_location('homo_sapiens', 'X', 'variation', 136648193, 136660390);$$,
  'The allowable feature names are checked and if the given feature name is not recognised, ' ||
  'an exception is thrown. The recognised ENUMs are represented as an array and the values were ' || 
  'taken from this link: https://rest.ensembl.org/documentation/info/overlap_region ' ||
  'The returned JSON is an array of JSON objects and it can be very large.'
);

SELECT create_function_comment_statement(
  'ensembl.get_uniprot_fastas_for_species_gene',
  ARRAY['TEXT[]', 'TEXT'],
  'Given an array of species names and a gene name, return the amino acid sequences for each gene in FASTA format.',
  $$SELECT ensembl.get_uniprot_fastas_for_species_gene(ARRAY['homo_sapiens', 'mus_musculus'], 'CD38');$$,
  'This function gets its FASTA sequences from the UniProt REST API and not the Ensembl one. ' ||
  'It should be moved to the uniprot schema!');

SELECT create_function_comment_statement(
  'ensembl.get_ensembl_json',
  ARRAY['TEXT'],
  'Returns JSONB for a given URL extension',
  $$SELECT * FROM ensembl.get_ensembl_json('/lookup/id/ENSG00000157764?expand=1');$$,
  'This function is written in Python. ' ||
  'It centralizes all calls to the Ensembl REST API, see: https://rest.ensembl.org/documentation. ' ||
  'Individual PL/pgSQL functions use it to get specific JSONB return values. ' ||
  'The second part of the URL, *p_ext* is expected to be fully formed with the parameters ' || 
  'already inserted by the calling code. It requires the Python *requests* module to be installed.');
  
SELECT create_function_comment_statement(
  'ensembl.get_details_for_id_as_json',
  ARRAY['TEXT'],
  'Return details as JSONB for a given Ensembl identifier e.g. gene, transcript, protein.', 
  $$SELECT * FROM ensembl.get_details_for_id_as_json('ENSG00000157764');$$,
  'Notes: Only accepts Ensembl identifiers and throws an error if the given identifier does not begin with *ENS*. ' ||
  'Calls a stored Python FUNCTION ensembl.that does the actual REST API call. ' || 
  'See Ensembl REST API documentation: https://rest.ensembl.org/documentation/info/lookup');

SELECT create_function_comment_statement(
  'ensembl.get_details_for_symbol_as_json',
  ARRAY['TEXT', 'TEXT'],
  'Return details as JSONB for a given symbol, a gene name for example, and species name.',
  $$SELECT * FROM ensembl.get_details_for_symbol_as_json('CD38', 'mus_musculus');$$,
  'Takes the Latin name for *species*, *mus_musculus* or *homo_sapiens*. ' ||
  'See documentation https://rest.ensembl.org/documentation/info/symbol_lookup');

SELECT create_function_comment_statement(
  'ensembl.get_variant_table_for_gene_symbol',
  ARRAY['TEXT', 'TEXT'],
  'Return a table of all the variants (excludes structural variants) for a given gene symbol and species.', 
  $$SELECT * FROM ensembl.get_variant_table_for_gene_symbol('CD38', 'homo_sapiens');$$,
  'It uses the gene symbol to extract the gene object JSON from which it gets the chromosome and ' ||
  'gene start and stop coordinates. It then calls the function *ensembl.get_features_for_genomic_location* ' ||
  'passing in the required gene location arguments, extracts some values from the JSON and returns a table. ' ||
  'An exception is raised if the gene symbol is not recognised.');

SELECT create_function_comment_statement(
  'ensembl.get_variation_info_as_json',
  ARRAY['TEXT', 'TEXT'],
  'Return details as JSONB for a given variation name and species name.', 
  $$SELECT * FROM ensembl.get_variation_info_as_json('rs7412', 'homo_sapiens');$$,
  'The returned JSONB object is information-rich for the variant.' ||
  'It provides position for the latest assembly, synonyms, consequences allele frequency and so on. ' ||
  'But it does not provide gene information, even for variants known to be intra-genic');
  
SELECT create_function_comment_statement(
  'ensembl.get_protein_ids_table_for_gene_ids',
  ARRAY['TEXT'],
  'Return a table of protein information for the given Ensembl gene ID.',
  $$SELECT * FROM ensembl.get_protein_ids_table_for_gene_ids('ENSG00000004468');$$,
  'The returned table contains all the Ensembl protein IDs for the input gene ID, ' ||
  'the translation length and a flag to inform if it is the canonical sequence for that gene. ' ||
  'It will throw an exception if the given gene ID is not recognised.');

SELECT create_function_comment_statement(
  'ensembl.get_protein_sequence_as_text_for_gene_id',
  ARRAY['TEXT'],
  'Return the canonical protein sequence for a given Ensembl gene ID.',
  $$SELECT ensembl.get_protein_sequence_as_text_for_gene_id('ENSG00000130203');$$,
  'This function sometimes returns a much longer sequence than the canonical Uniprot sequence. ' ||
  'For this reason, it is better to get this information from Uniprot');

SELECT create_function_comment_statement(
  'ensembl.get_gene_id_for_species_name',
  ARRAY['TEXT', 'TEXT'],
  'Return the Ensembl gene ID for a given gene name and species name.',
  $$SELECT ensembl.get_gene_id_for_species_name('homo_sapiens', 'CD38');$$,
  'It returns the first gene ID from the JSONB object returned by *ensembl.get_details_for_symbol_as_json*. ' ||
  'It uses SELECT INTO in non-strict mode so will not raise an error if the row count is <1 or >1.');
  
SELECT create_function_comment_statement(  
  'ensembl.get_fastas_for_species_gene',
  ARRAY['TEXT[]', 'TEXT'],
  'Return protein sequences in FASTA format for a given an array of species names and a gene name', 
  $$SELECT ensembl.get_fastas_for_species_gene(ARRAY['homo_sapiens', 'macaca_mulatta'], 'CD38');$$,
  'Used to get gene orthologs for a set of species for a particular gene. ' ||
  'The output can be used by various bioinformatics tools to do sequence comparisons.');

SELECT create_function_comment_statement(   
  'ensembl.get_xref_info_for_ensembl_id',
  ARRAY['TEXT'],
  'Return JSON containing details of all cross-references for the given Enseml ID.',  
  $$SELECT * FROM ensembl.get_xref_info_for_ensembl_id('ENSG00000004468');$$,
  'The given can be any sort of Ensembl ID (gene, protein transcript) for any species in Ensembl. ' ||
  'It is assumed to begin with *ENS* and error will be generated if the ID is not recognised.');

SELECT create_function_comment_statement( 
  'ensembl.get_xref_table_for_ensembl_id',
  ARRAY['TEXT'],
  'Return a table of desired values extracted from JSON with full cross-reference information for the given Ensembl ID.',
  $$SELECT * FROM ensembl.get_xref_table_for_ensembl_id('ENSG00000004468');$$,
  'The Ensembl ID can be any type of valid Ensembl ID, gene protein, etc. It is assumed to begin with *ENS*. ' ||
  'This function is very useful for getting cross-references for the given Ensembl ID in non-Ensembl stystems.');

SELECT create_function_comment_statement( 
  'ensembl.get_fasta_for_gene_from_uniprot',
  ARRAY['TEXT'],
  'Return the amino acid sequence for the given UniProt ID in FASTA format.',  
  $$SELECT * FROM ensembl.get_fasta_for_gene_from_uniprot('P28907');$$,
  'Use this function to get the definitive amino acid sequence for a protein. ' ||
  'Uses the UniProt REST API. Should be moved to the UniProt schema.');

SELECT create_function_comment_statement( 
  'ensembl.get_uniprot_id_for_ensembl_gene_id',
  ARRAY['TEXT'],
  'Return the Uniprot ID for a given Ensembl gene ID.', 
  $$SELECT * FROM ensembl.get_uniprot_id_for_ensembl_gene_id('ENSG00000004468');$$,
  'This function throws an error if there is more than one UniProt ID associated with ' ||
  'the Ensembl gene ID. For example, for the mouse verion of CD38, its Ensembl ID *ENSMUSG00000029084* ' ||
  'throws *ERROR:  query returned more than one row*.');

SELECT create_function_comment_statement( 
  'ensembl.get_uniprot_id_array_for_ensembl_gene_id',
  ARRAY['TEXT'],
  'Return an array of UniProt IDs for the given Ensembl gene ID.',
  $$SELECT * FROM ensembl.get_uniprot_id_array_for_ensembl_gene_id('ENSG00000268895');$$,
  'The function *ensembl.get_uniprot_id_array_for_ensembl_gene_id* throws an error if the ' ||
  'given Ensembl gene ID is associated with more than one UniProt ID. This function deals ' ||
  'with this situation by returning an array of UniProt IDs. ' ||
  'It returns NULL if there are no matching UniProt IDs.');
  
SELECT create_function_comment_statement( 
  'ensembl.get_vep_for_variation_id',
  ARRAY['TEXT', 'TEXT'],
  'Return the Variant Effect Predictor JSONB array for a given species name and variation ID.',  
  $$SELECT * FROM ensembl.get_vep_for_variation_id('rs7412', 'homo_sapiens');$$,
  'The returned JSONB is an array that contains some complex nested objects. ' ||
  'This function call is often very slow so should be used with cautions and avoided if possible ' ||
  'because it is subject to timeout errors from the REST server.');
  
SELECT create_function_comment_statement('ensembl.get_details_for_id_array_as_json', 
                                         ARRAY['TEXT[]'], 
                                         'Returns an array of JSONB objects received from the Ensembl REST API for the input array of Ensembl IDs.', 
                                         $$SELECT * FROM ensembl.get_details_for_id_array_as_json(ARRAY['ENSG00000275026', 'ENSG00000232433', 'ENSG00000172967', 'ENSG00000237525', 'ENSG00000185640', 'ENSG00000276128', 'ENSG00000227230', 'ENSG00000243961']);$$, 
                                         'The function initialises an array of the same length as the argument array with empty JSONB objects' ||
                                         'Each element of the initialised array will be populated with the JSON returned by the REST API call (*ensembl.get_details_for_id_as_json*) or ' || 
                                         ' a JSONB indicating an error with that ID. The returned array has to be the same length as the input argument array. ' ||
					 'The inner block in the *FOREACH* loop traps exceptions thrown when the REST API returns an error. ' ||
					 'Currently, the type of error is not reported so it could be due to a bad ID (one that does not exist or that has been deprecated) ' ||
					 'or due to a server-side API error.' ||
					 'The *PERFORM PG_SLEEP(1);* code line is added to ensure that the REST API does not throw an over-use error.');
