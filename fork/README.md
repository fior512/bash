# fork.sh

Clones your fork of a GitHub/GitLab repo and wires up the `upstream` remote in one step, for fast OSS contribution setup. Assumes the fork already exists on the platform (it does not create the fork for you).

## Usage

```bash
./fork.sh <official-repo-url> [your-username]
```

```bash
./fork.sh https://github.com/torvalds/linux
./fork.sh https://github.com/torvalds/linux other-username
```

Result: clones `git@<platform>:<username>/<repo>.git` into `./<repo>`, then adds the official repo as `upstream`.

## Implementation

| | |
|---|---|
| Lines | 40 |
| Dependencies | `git`, `bash` |
| Parametrization | Username comes from the `FORK_USERNAME` env var or the optional 2nd argument (argument wins). No username is hardcoded - the script exits with an error if neither is set. |

Platform (`github.com`, `gitlab.com`, ...) and repo name are parsed from the official repo URL. Clone uses the `git@` SSH form; swap to `https://` in the script if you don't have SSH keys set up.
