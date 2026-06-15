---
name: Bug report
about: Something broke, or the app doesn't do what the README says
labels: bug
---

**What happened**

<!-- What did the app do? -->

**What you expected**

<!-- What should it have done instead? -->

**Environment**

- iOS version:
- Airlift version:

**For wire-schema issues**

If the Google Health API returned something Airlift couldn't parse, a **redacted**
sample of the `dataPoints` JSON is the single most useful thing to attach — scrub
IDs and timestamps first (see [CONTRIBUTING.md](../../CONTRIBUTING.md)).
