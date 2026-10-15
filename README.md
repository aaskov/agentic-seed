# agentic-seed

A Copier template for app repositories where agents write the code and
machines check it. The architect reviews only contracts and decisions.

## Generate a project

```bash
uvx copier copy git@github.com-personal:aaskov/agentic-seed.git ~/personal/<project>
cd ~/personal/<project>
git init -b main
git remote add origin git@github.com-personal:aaskov/<project>.git
```

Then open the project in its devcontainer and run `mise run check`.

## Update a project

Run `uvx copier update` in the project, on an `architect/` branch. Copier
uses the latest tag of this repository. Tag each release, for example `v0.2.0`.

## What a project gets

See `template/README.md.jinja` and the decisions in `template/docs/adr/`.

## Test the template

```bash
tests/test_template.sh
```

The test generates a project, builds its devcontainer, and runs the gate in
that container. It needs Docker and the devcontainer CLI. CI runs the same
test on each push and each pull request.
