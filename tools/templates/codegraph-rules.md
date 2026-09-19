@BEGIN@
<!-- rules=@RULES_VERSION@ — regenerate with `@CTL@ rules --dir @REPO@` -->
## Code graph (structural questions go through the graph first)

This repository is folded into the **`@PLANE@`** plane, re-folded on every
commit, and served by the `drsg-watch` MCP tools on `http://@ADDR@/mcp`. It
models: @LABELS@. For its current size and the commit it is synced up to, ask
`describe_plane` or run `@CTL@ status --dir @REPO@` — no count is written down
here, because a count in a document is wrong one commit later.

**Every call must pass `plane: "@PLANE@"`.** The tools default to `startup`,
which is an empty plane, and its answer — `no symbol matches` — is
indistinguishable from the graph genuinely not knowing. In the first audit of
this setup, plane addressing accounted for 6 of the 8 empty answers; only 2
were real gaps.

**The check on an answer is the graph's own symbol key.** A structural claim
must quote the full key the graph returned — `crate::module::Symbol`,
`github.com/acme/example/pkg.Type.Method` — not just a `file:line`, because grep
prints `file:line` too and so a rule written on it cannot catch its own
violation.

**The trigger is in the answer, not in the question.** The moment a reply
contains a quantified structural claim — "only X callers", "nothing uses it",
"nothing else is affected", "these are the places to change" — that claim has
to come from the graph, however casual the question sounded.

| Question | Verb |
|---|---|
| who calls X / all of X at once | `context` (start here) |
| what does changing X affect | `impact` |
| how does A reach B | `trace` |
| where is X, what is its signature | `describe` |
| give me the source of X | `snippet` |
| what is in the plane at all | `describe_plane`, `cypher` |
| text the graph does not model | `grep` (searches the watched tree) |

**A change question is not answered until `impact` has run.** Asking what
changing, renaming or deleting X reaches is a different question from who calls
X, and `context` cannot answer it: it walks one hop. Any reply about the reach
of a change must quote `impact`, which groups what it found by distance and
counts each group — a caller list does not have that shape, so pasting one is a
visible substitution, not an answer. `impact` finding nothing past distance 1 is
itself the answer; say so. It counts recorded edges only and says as much in its
own output — carry that caveat with the number, it is a lower bound. The same
rule holds for `trace`: a claim that A reaches B quotes the path `trace`
returned, hop by hop.

Expect to break this one. Over the first month of this setup `context` was
called 46 times, `impact` once, and `trace` never — every question about blast
radius was answered by the verb that only sees one hop, and none of those
answers looked wrong at the time.

**Ask with a symbol name, not a description.** `context` resolves a string in
three passes (exact key, then `::name`/`.name` suffix, then case-insensitive
substring). Naming a file sends the answer to `Read`; naming a symbol goes to
the graph. The third pass is the boundary: a descriptive word works only if it
is a substring of some symbol's name, so `plugin` resolves and a phrase in prose
— or in a language the code is not written in — does not. That is `grep`'s job,
and the answer has to say so.

**An ambiguous name is not a failure, but the candidate list is capped at 20 and
is not ranked by relevance.** Past about 20 candidates, do not pick from what is
shown — narrow and ask again, because the right symbol may be in the part that
was folded away. `Type::method` is the narrowing that usually lands in one call.
With 2–10 candidates, `describe` each and choose from the signatures: a function
returning another crate's type is usually a wrapper, and running `impact` on the
wrapper reports a strictly smaller blast radius than the thing it delegates to.

**Raise `impact`'s depth until a group comes back empty.** It walks 3 hops by
default, and cutting off where propagation has not stopped yields the first
three hops rather than the reach; two symbols measured at different depths are
not comparable. The empty group is the evidence that the answer is complete.

**The graph will also tell you it does not know**, and that is worth more than
a guess: the `UnresolvedRef` nodes are exactly where the parsers gave up (there
are thousands — `describe_plane` counts them), and cross-language edges are
generally broken. Comments (`//`), string
literals, and files no plugin claims (`.md`, `.sh`, CI config) are not modelled
at all. Use `grep` there and **say that the answer came from grep** — an empty
graph result is a finding to report, never a reason to fall back to impressions.

Daemon: `@CTL@ {start|stop|restart|status|rules} --dir @REPO@`. One per
repository; the address and token both live in `.mcp.json`, so never mint a new
token — that invalidates every client config `drsg init` wrote.
@END@
