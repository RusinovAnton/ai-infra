Implement a TypeScript function `diffSemver(a: string, b: string)` returning
`"major" | "minor" | "patch" | "prerelease" | "equal" | "invalid"` — the most
significant part in which the versions differ. Handle pre-release tags per
semver precedence (`1.0.0-alpha` < `1.0.0`; numeric identifiers compare
numerically, alphanumeric lexically). Build metadata (`+meta`) is ignored. A
leading `v` is accepted. No dependencies. Include the function and 8–10 test
cases as plain assertions.

## Rubric

- core comparison correct on plain versions: 0–3
- pre-release precedence correct (alpha < release, numeric vs alpha identifiers, identifier count): 0–3
- build metadata ignored, leading `v` handled, garbage → `"invalid"`: 0–3
- tests cover the tricky cases rather than restating the happy path: 0–3
