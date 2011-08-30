#!/usr/bin/python

"""
Copyright (c) 2010 Luca de Alfaro.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. The names of the contributors may not be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
"""

import sys
import csv
from revision_selection import classify, is_page_ok, get_random_page_id

def usage():
    print """cat <datafile> | ./genewiki_stats.py 50 > outfile.csv
    where '50' is the number of revisions to analyze for each article."""

if len(sys.argv) != 2:
    usage()
    sys.exit(2)

num_revisions = int(sys.argv[1])

# Minimum page requirements to avoid redirects and too-short pages.
MIN_PAGE_LENGTH = 200
MIN_PAGE_REVISIONS = 20

# csv file initialization
fieldnames = ("Page_id", "Is_genewiki", "Average_length", "Frac_vandalism",
              "Frac_neg_qual", "Frac_reverts", "Avg_quality", "Avg_untrusted_text",
              "Frac_untrusted_text", "Average_trust", "Average_reputation")

writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames,delimiter='\t',
                        quoting=csv.QUOTE_MINIMAL)
headers = dict( (n,n) for n in fieldnames )
writer.writerow(headers)

def write_row(out):
    row = {}
    for f in fieldnames:
        row[f] = out.get(f, None)
    writer.writerow(row)

def truncate(x, n):
    k = 10 ** n
    return float(int(x * k)) / float(k)

# We keep track of how many GeneWiki pages we analyze, so that we analyze a similar number
# of other pages.
n_genewiki_pages_analyzed = 0
for l in sys.stdin:
    try:
        ll = l.split('\t')
        page_id = int(ll[0])
        if is_page_ok(page_id, MIN_PAGE_REVISIONS, MIN_PAGE_LENGTH):
            n_genewiki_pages_analyzed += 1
            out = compute_quality_stats(page_id, num_revisions)
            out["Is_genewiki"] = 1
            write_row(out)
    except ValueError:
        pass
    
# Now analyzes the same number of general pages.
for i in range(n_genewiki_pages_analyzed):
    page_id = get_random_page_id(min_revisions=MIN_PAGE_REVISIONS,
                                 min_length=MIN_PAGE_LENGTH)
    out = compute_quality_stats(page_id, num_revisions)
    out["Is_genewiki"] = 1
    write_row(out)
