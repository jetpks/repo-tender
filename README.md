# repo-tender 🌲

[![Gem Version](https://badge.fury.io/rb/repo-tender.svg)](https://badge.fury.io/rb/repo-tender)

> **Keep your local git clones forever fresh!** ヽ(•‿•)ノ✨

`repo-tender` keeps your local git clones **evergreen** — clean, on their
default branch, and recently fetched — so anything that reads them gets a
current, trustworthy copy from your local disk instead of the network. A
periodic launchd sweep does the tending; nothing downstream ever waits on a
remote fetch again. 🪞⚡

## Install 📦

```bash
gem install repo-tender
```

macOS-only (it schedules via launchd) and GitHub-only (it lists orgs via
`gh`). Ruby 4.0.5+, git 2.54+, and an authenticated `gh` for org tracking —
see [Requirements](docs/reference/config-and-paths.md#requirements).

## 60-second start 🎀

```bash
repo-tender repo add github.com/ruby/ruby   # track a repo
repo-tender sync                            # clone it evergreen-style locally
repo-tender status                          # check its health
```

That's the whole loop — or take the [5-minute tutorial](docs/tutorials/README.md).

## Where to go next 🧭

repo-tender's docs follow the [Diátaxis](https://diataxis.fr/) quartet —
each kind of doc answers a different question:

| Quadrant | Question it answers | Start here |
|----------|--------------------|------------|
| [Tutorials](docs/tutorials/README.md) | *"Teach me, step by step"* | [Your first evergreen repo](docs/tutorials/first-evergreen-repo.md) |
| [How-to guides](docs/how-to/README.md) | *"How do I…?"* | [Track repos and orgs](docs/how-to/track-repos-and-orgs.md) |
| [Reference](docs/reference/README.md) | *"What exactly does…?"* | [CLI reference](docs/reference/cli.md) |
| [Explanation](docs/explanation/README.md) | *"Why is it this way?"* | [What "evergreen" means](docs/explanation/evergreen.md) |

## License 📄

Available as open source under the terms of the [MIT License](LICENSE.txt).

---

Made with 💖 and a deep distrust of `reset --hard`, by Eric 🌲
