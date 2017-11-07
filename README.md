
# Summary
This repository contains notes on how to develop a PostgreSQL-backed R Shiny web application. The application is uses PL/pgSQL heavily and all interaction between R and the PostgreSQL database is mediated by PL/pgSQL stored functions. The R Shiny application uses a read-only account and cannot therefore alter data in the database.

# Using the Code Examples
All the code examples are available in [this file](https://github.com/Rotifer/PostgreSQLShiny/blob/master/PostgreSQLBackedRShinyApplicationNotes.md). I will try to explain the examples and give links to external resources but a basic knowldege of R and SQL is assumed. If you can program and know SQL, then PL/pgSQL should not be difficult.

# Example Data
I wrote the notes while developing an R Shiny application to view and analyse [RNA gene expression](https://en.wikipedia.org/wiki/Gene_expression) data from the [Cancer Cell Line Encyclopedia](https://portals.broadinstitute.org/ccle). Even those who have no knowledge of, or interest in, this type of work should be able to follow along provided they have sufficient knowldege of R/SQL and want to learn using examples.
