# Query the archive (MCP)

`grep`-ing the logs finds a chat by a word you remember typing. The harder case — *"I discussed X* *somewhere* *a while ago, which machine was it even on?"* — is what the **`dcmcp`** MCP server solves: a **read** path back into a live session over everything the relay already wrote (transcripts, plans, cross-machine memory), so you can recall a past session by *topic* and pull it — or just the relevant slice — straight into context without leaving Claude.

It's a single-file, **read-only** server (`mcp/dcmcp_server.py`, run via `uv run --script`) that reads the same storage pointers as the rest of dotclaude (`DOTCLAUDE_LOCAL_CHATS`, `DOTCLAUDE_MEMORY`, `DOTCLAUDE_DATA`). Recall is deliberately **embedding-free** — a fast ripgrep prefilter (grep fallback) surfaces candidate snippets and the in-session model does the semantic ranking — so there's no index to build and nothing sensitive ever leaves the NAS. It also folds the `logs/<host>.log` **session catalogue** into recall: a topic match there links to the transcript when present, or stands alone as a "you had this on `<host>`" pointer — so recall spans even sessions whose full transcript isn't on the machine you're asking from. It exposes:

| Surface       | What                                                                                                                                                                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **tools**     | `dc_list` (browse w/ filters, incl. `type=log` for the catalogue), `dc_recall` (topic → ranked candidates + anchors), `dc_search_within` (a topic *inside* one session → turn/line anchors), `dc_get` (fetch an artifact or a `turns=`/`lines=` slice), `dc_status` |
| **resources** | every transcript/plan/memory as an `@`-pickable resource (`dc://transcript/…`, `dc://plan/…`, `dc://memory/…`) with a human, date-sorted title                                                                                                                      |
| **commands**  | `/dcrecall <topic>`, `/dcfind <topic> in <session>`, `/dcbrowse [type]`, `/dcget <ref>` — thin wrappers that drive the tools (full list under [Slash commands](https://henba1.github.io/dotclaude/slash-commands/index.md))                                         |

## Registration is automatic, three ways

All done by `claude-sync.sh` at **user scope**, picked by what this machine has:

- **On a GitHub (`git` backend) machine** — the `claude-chats` clone *is* the archive: the relay writes the same `<host>/{readable,plans,…}` tree into it that a NAS holds, so `claude-sync.sh` registers a local stdio server pointed straight at the clone. `sync-session.sh` `git pull`s the clone at the start of each session, so recall spans **every** machine's sessions, not just this one's. No NAS, WireGuard, or SSH — nothing to authorize. (Cross-machine *memory* recall still needs memory sync wired separately; transcripts, plans, and the logs catalogue work out of the box.)
- **On the archive host** (the always-on home server where `DOTCLAUDE_LOCAL_CHATS` → the NAS is mounted): a local stdio server reads the mounted archive directly. Nothing to do beyond onboarding.
- **On a client with no local archive** (a laptop, or an **HPC login node**): run `bin/onboard-mcp-client.sh` (offered by `onboard.sh`). It points `DOTCLAUDE_MCP_REMOTE` at the archive host and registers an `ssh` entry; on connect, a forced command (`bin/dcmcp-serve.sh`) runs the server **on the archive host** and pipes MCP stdio back over the same SSH/ProxyJump path the relay uses. The server side stays a manual `authorized_keys` authorize (printed by the script), like the relay + memory keys. **One mechanism covers both kinds of client:** a laptop on the WireGuard mesh, *and* an HPC login node that can't join it — clusters typically block the outbound UDP that WireGuard needs, so those nodes fall back to plain SSH/ProxyJump instead. If neither path applies, `claude-sync.sh` prints a loud, actionable skip rather than silently doing nothing.

## The remote transport (SSH-stdio)

A client with no local archive registers `dcmcp` as a *stdio* server whose command is `ssh <alias>`. That SSH **jumps the edge/bastion** (ProxyJump) to reach the archive host on the home LAN, where a forced command launches the read-only server; MCP JSON-RPC rides the pipe. The clever bit is the **two nested SSH sessions**: an *outer* one authenticates to the edge (whose key is restricted to forwarding a single port — no shell), and an *inner*, **end-to-end** session runs through that tunnel to the archive host. So the edge only ever relays opaque ciphertext — it can't read or tamper with the MCP traffic. Auth is asymmetric (an `ed25519` key, verified at both hops); the tunnel itself is the usual symmetric SSH channel.

Diagram source: [`transport-mcp.dot`](https://henba1.github.io/dotclaude/transport-mcp.dot) — `dot -Tsvg docs/transport-mcp.dot -o docs/transport-mcp.svg`. Placeholder DDNS name + default ports; substitute your own.

## The one manual step — authorize the client on the archive host

`onboard-mcp-client.sh` does everything on the client, then prints the exact line(s) to install by hand (the server side is never automated — same rule as the relay + memory keys). Each key is pinned to the read-only server and nothing else:

- **On the archive host**, add to the **owner account**'s `~/.ssh/authorized_keys` (the account with `uv` + the dotclaude clone + archive read — *not* the write-only relay account). The forced command confines the key to the one server, so a leaked key can only run read-only archive queries:

```
command="<abs-path-to-clone>/bin/dcmcp-serve.sh",restrict <the printed public key>
```

- **If the path crosses a ProxyJump edge/bastion** (e.g. an HPC client), also add to the jump user's `~/.ssh/authorized_keys` **on the edge** — letting the key tunnel only to the archive host's port, run nothing:

```
restrict,port-forwarding,permitopen="<archive-host>:<port>",command="/bin/false" <the printed public key>
```

Then verify from the client — \`ssh
