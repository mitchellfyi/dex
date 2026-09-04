# Review Risk Assessment

Choose the review risk tier before the first review wave. Inspect the supplied
scope, but do not edit files, change git state, install tools, or run commands
that can mutate the checkout.

Apply this ordered rubric. The first matching rule wins:

1. Choose `complex` when the scope touches a trust boundary; authentication,
   authorization, permissions, secrets, payments, or destructive behavior;
   persistence, schemas, or migrations; public API, CLI, configuration, or
   compatibility contracts; concurrency or process lifecycle; hooks, guards,
   CI, deployment, or packaging; broad cross-module behavior; or when material
   uncertainty prevents the supplied scope or its verification from being
   bounded.
2. Choose `small` only when every change is localized and mechanically direct,
   impact is narrow, focused verification is available, and none of the
   `complex` conditions applies.
3. Choose `normal` for everything else.

Use one or more of these comma-separated reason codes:

`localized-change`, `focused-verification`, `bounded-production-change`,
`cross-module`, `public-contract`, `security-sensitive`, `data-migration`,
`concurrency`, `shell-hooks-ci`, `deployment-packaging`, `broad-impact`,
`uncertain-coverage`.

The codes must agree with the tier. `small` uses both
`localized-change,focused-verification` and no other code. `complex` includes at
least one matching complex-risk code: `cross-module`, `public-contract`,
`security-sensitive`, `data-migration`, `concurrency`, `shell-hooks-ci`,
`deployment-packaging`, `broad-impact`, or `uncertain-coverage`. `normal` uses
only non-complex codes and must not claim the exact `small` pair;
`bounded-production-change` is the usual normal-tier reason.

Use `uncertain-coverage` only when a concrete gap in the supplied scope or
available verification leaves material behavior unbounded. Do not use it just
because the repository is small, unfamiliar, lacks a package manifest, or
because a higher tier feels safer. If the complete diff is enumerable and its
behavior has focused verification, apply the other rules without adding an
uncertainty penalty.

Return the decision in the exact structured format requested by the caller.
The caller owns persistence; a read-only assessor must not write review state.
Do not put free-form prose, paths, source excerpts, or secrets in the reason-code
field. The tier maps deterministically to the required consecutive clean waves:
the caller resolves the exact requirement from the trusted review policy before
the first wave.

The same tier supplies a soft outer-wave budget of 3, 6, or 9 respectively.
That budget is operational and may be changed through an attributed
`review.max-waves` override without changing the assurance tier.
