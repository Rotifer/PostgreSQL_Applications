CREATE OR REPLACE FUNCTION uniprot.get_record_for_uniprot_id(p_uniprot_id TEXT)
RETURNS XML
AS
$$
    import requests
    
    url= "http://www.uniprot.org/uniprot/%s.xml"
    url = url % (p_uniprot_id,)
    response = requests.get(url, headers={ "Content-Type" : "application/xml"})
    if not response.ok:
        response.raise_for_status()
    
    return response.content
$$
LANGUAGE 'plpythonu'
STABLE
SECURITY DEFINER;
-- Added the comment documentationin in a JSON-convertible format that I wrote for this purpose.
SELECT create_function_comment_statement('uniprot.get_record_for_uniprot_id',
                                        ARRAY['TEXT'],
                                        'Return the full XML document for a given Uniprot ID.',
                                        $$SELECT uniprot.get_record_for_uniprot_id('P01589');$$,
                                        'This XML document will need to be parsed to extract the required information.');
