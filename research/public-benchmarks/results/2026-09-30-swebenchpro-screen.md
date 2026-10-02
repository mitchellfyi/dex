# SWE-bench Pro screen, 30 September 2026

Plain Claude Code on the screening set: two tasks from each of SWE-bench Pro's
11 repositories ([`tasksets/swebenchpro-screen.txt`](../tasksets/swebenchpro-screen.txt)).
No Dex arm ran. This is round 1 of the plan in the [README](../README.md#which-parts-of-dex-to-test).

| | |
|---|---|
| Dataset | `swebenchpro@1.0` (Harbor legacy registry) |
| Agent | Harbor `claude-code`, Claude Code 2.1.285 |
| Model | `claude-sonnet-5-5`, default effort |
| Limits | 50-minute agent limit (multiplier 1); 3× setup time |
| Host | Apple Silicon Mac, Docker Desktop, x86 images under emulation, one task at a time |
| Run | `swebenchpro-1.0-claude-code-20260930-173846` in `~/.dex/bench/jobs` (not committed) |

**14 solved, 6 failed, 2 errored, $2.57 in total.** The solve rate is
14/20 of the tasks the verifier scored. Agent time averaged about 7 minutes; wall time was
about 5.5 hours, most of it emulated container setup.

| Task | Outcome | Cost | Agent seconds | Note |
|------|---------|------|---------------|------|
| `instance_ansible__ansible-984216f52e76b904e5b0fa0fb956ab4f1e0a7751-v1055803c3a812189a1133297f7f5468579283f86` | solved | $0.41 | 151 |  |
| `instance_ansible__ansible-a20a52701402a12f91396549df04ac55809f68e9-v1055803c3a812189a1133297f7f5468579283f86` | solved | $0.06 | 24 |  |
| `instance_element-hq__element-web-18c03daa865d3c5b10e52b669cd50be34c67b2e5-vnan` | solved | $0.04 | 127 |  |
| `instance_element-hq__element-web-56c7fc1948923b4b3f3507799e725ac16bcf8018-vnan` | failed | $0.09 | 162 |  |
| `instance_flipt-io__flipt-c6a7b1fd933e763b1675281b30077e161fa115a1` | failed | $0.23 | 1170 |  |
| `instance_flipt-io__flipt-cd2f3b0a9d4d8b8a6d3d56afab65851ecdc408e8` | failed | $0.14 | 662 |  |
| `instance_future-architect__vuls-7e91f5ef7e5712b1a3d7d5066ad6607e9debc21c` | solved | $0.08 | 3000 | hit the 50-minute agent limit; the fix was already on disk |
| `instance_future-architect__vuls-f6509a537660ea2bce0e57958db762edd3a36702` | solved | $0.10 | 779 |  |
| `instance_gravitational__teleport-6eaaf3a27e64f4ef4ef855bd35d7ec338cf17460-v626ec2a48416b10a88641359a169d99e935ff037` | errored |  |  | Claude Code install failed: Debian 11 security mirror 404s for nodejs |
| `instance_gravitational__teleport-c335534e02de143508ebebc7341021d7f8656e8f` | errored |  |  | Claude Code install failed: Debian 11 security mirror 404s for nodejs |
| `instance_internetarchive__openlibrary-798055d1a19b8fa0983153b709f460be97e33064-v13642507b4fc1f8d234172bf8129942da2c2ca26` | failed | $0.07 | 24 |  |
| `instance_internetarchive__openlibrary-c506c1b0b678892af5cb22c1c1dbc35d96787a0a-v0f5aece3601a5b4419f7ccec1dbda2071be28ee4` | solved | $0.05 | 24 |  |
| `instance_navidrome__navidrome-3972616585e82305eaf26aa25697b3f5f3082288` | failed | $0.25 | 264 |  |
| `instance_navidrome__navidrome-8383527aaba1ae8fa9765e995a71a86c129ef626` | solved | $0.09 | 247 |  |
| `instance_nodebb__nodebb-1ea9481af6125ffd6da0592ed439aa62af0bca11-vd59a5728dfc977f44533186ace531248c2917516` | solved | $0.07 | 30 |  |
| `instance_nodebb__nodebb-70b4a0e2aebebe8f2f559de6680093d96a697b2f-vnan` | solved | $0.09 | 35 |  |
| `instance_protonmail__webclients-2f2f6c311c6128fe86976950d3c0c2db07b03921` | failed | $0.33 | 1206 |  |
| `instance_protonmail__webclients-3f22e2172cbdfd7b9abb2b1d8fd80c16d38b4bbe` | solved | $0.17 | 272 |  |
| `instance_qutebrowser__qutebrowser-5fdc83e5da6222fe61163395baaad7ae57fa2cb4-v363c8a7e5ccdf6968fc7ab84a2053ac78036691d` | solved | $0.10 | 186 |  |
| `instance_qutebrowser__qutebrowser-ed19d7f58b2664bb310c7cb6b52c5b9a06ea60b2-v059c6fdc75567943479b23ebca7c07b5e9a7f34c` | solved | $0.08 | 74 |  |
| `instance_tutao__tutanota-219bc8f05d7b980e038bc1524cb021bf56397a1b-vee878bb72091875e912c52fc32bc60ec3760227b` | solved | $0.06 | 49 |  |
| `instance_tutao__tutanota-fe240cbf7f0fdd6744ef7bef8cb61676bcdbb621-vc4e41fd0029957297843cb9dec4a25c7c756f029` | solved | $0.05 | 19 |  |

## Hard set

The six failures. They span five repositories and three languages, and two
kinds of failure: long attempts that still missed (flipt twice, protonmail),
and quick confident answers that were wrong (openlibrary in 24 seconds,
element-web, navidrome).

## Next: round 2

Plain Claude Code again (its retry rate), full Dex, and Dex with Implement
only, on the hard set plus four of the passes (a fixed-seed sample, to catch
Dex breaking easy tasks and to measure its overhead). 30 trials: on this Mac
about 10-14 hours and $25-40.

```bash
source ~/.dex/bench/credentials
R=swebenchpro-1.0-claude-code-20260930-173846
research/public-benchmarks/run.sh --agent claude-code,dex,dex-implement \
  --dataset swebenchpro@1.0 --failed-in "$R" --passed-in "$R" --sample 4 \
  --one-at-a-time --prune-images
```

The raw jobs live only on the machine that ran them. Without them,
`--failed-in` has nothing to read; pass the six task names above with
`--task` instead.
