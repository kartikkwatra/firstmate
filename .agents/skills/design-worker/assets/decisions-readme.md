# Decisions

Each numbered file here records one product decision in the MADR format, managed with [adr-tools](https://github.com/npryce/adr-tools).

Only a record whose Status section reads `Accepted` is current; follow those records.
A record whose Status reads `Superceded by` (adr-tools' spelling) is history, replaced by the newer record it links to.
A `Proposed` record is not decided yet and is not an instruction.
A changed decision gets a new record that supersedes the old one (`adr new -s <number> <title>`); a record's content is never rewritten.
`templates/template.md` is the template new records start from.
