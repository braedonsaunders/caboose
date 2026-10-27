# Working on Caboose

Read `docs/architecture.md` first. It is the contract between the app, the host,
and the guest; change it in the same pull request as any code that changes a
contract.

- **Quality bar: shipping product, open source from day one.** No placeholders,
  no TODO stubs presented as features, no mock data in product paths. If a piece
  is not done, it is absent and the docs say so.
- **AppKit first.** Use `@braedonsaunders/appkit-*` packages where one fits. When
  AppKit lacks something Caboose needs and Bunkhouse could also use, add it to
  AppKit (`~/Documents/Code/appkit` / github.com/braedonsaunders/appkit) with a
  changeset, rather than building it privately here.
- **Each component stands alone.** `apps/ios`, `apps/host` and `guest/image` each
  have their own README with how to build, run, and test that piece.
- **Tests.** Pure logic is unit-tested (Swift `swift test`, TypeScript `vitest`).
  Anything touching KVM, Xpra or a device is covered by a scripted check that can
  be run against a real host and is documented next to the code.
- **Commits.** Small, descriptive, imperative subject lines. Work on a branch and
  open a pull request into `main`; keep `main` green.
- **Secrets.** Never commit tokens, keys, pairing files, or host addresses that
  are not documentation examples.
