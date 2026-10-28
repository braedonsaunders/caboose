# Working on Caboose

These are the rules for contributing to Caboose, whether you are a person or a coding
agent.

Read [`docs/architecture.md`](docs/architecture.md) first. It is the contract between the
app, the host and the guest; change it in the same pull request as any code that changes
a contract. The display protocol's contract is [`docs/display.md`](docs/display.md), pinned
by the golden vectors in `guest/display/vectors`.

- **Quality bar: shipping product, open source.** No placeholders, no TODO stubs
  presented as features, no mock data in product paths. If a piece is not done, it is
  absent.
- **Documentation describes what exists.** Present tense, the current system only: no
  roadmaps, plans or history. A real limitation a user or contributor must know is stated
  once, plainly.
- **AppKit first.** Use the `@braedonsaunders/appkit-*` packages
  ([AppKit](https://github.com/braedonsaunders/appkit)) where one fits. AppKit is a shared
  library that other projects, such as Bunkhouse, also build on. When it lacks something
  Caboose needs and other AppKit users could use, add it to AppKit with a changeset rather
  than building it privately here.
- **Each component stands alone.** Every directory under `apps/` and `guest/` has its own
  README with how to build, run and test that piece, and its configuration.
- **Tests.** Pure logic is unit-tested: `swift test` in `apps/ios/CabooseKit`, `vitest`
  (`pnpm test` at the root) for the TypeScript packages, and `cargo test` in
  `guest/display`. Anything touching KVM, a display or a device is covered by a scripted
  check that can be run against a real host and is documented next to the code.
- **Commits.** Small, descriptive, imperative subject lines. Work on a branch and open a
  pull request into `main`; keep `main` green.
- **Secrets.** Never commit tokens, keys, pairing files, or host addresses that are not
  documentation examples.
