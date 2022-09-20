# ❄️+🪁 Generate Buildkite Pipelines from Nix Flakes

This repository contains some functions that'll transform a Nix flake into a
valid BuildKite Pipeline, represented in JSON.

## 🧑‍💻 Usage

We'll take a look at a minimal example flake that “builds” a packages named
`hello`, and “checks” that the output of running the `hello` package matches
`Hello, world!`. Here is that flake.

```nix
{
  description = "flake-buildkite-pipeline example";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.05";
    flake-buildkite-pipeline.url = "github:tweag/flake-buildkite-pipeline";
  };

  outputs = { self, nixpkgs, flake-buildkite-pipeline }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.hello = pkgs.hello;

      checks.${system}.demoCheck = pkgs.runCommandNoCC "demoCheck" {
        meta.checkDescription = "demoCheck";
      } ''
        set -o verbose
        want='Hello, world!'
        got="$(${self.packages.${system}.hello}/bin/hello)"
        [ "$want" == "$got" ]
        touch $out
      '';

      pipelines.buildkite.steps = flake-buildkite-pipeline.lib.flakeSteps {
        commonExtraStepConfig = {
          agents = [ "nix" ];
          plugins = [{ "thedyrt/skip-checkout#v0.1.1" = null; }];
        };
      } self;
    };
}
```

Apart from the `pipelines` attribute, everything looks like a normal flake, and
we can still use it a such. Try running `nix flake check`, and you can observe
that it builds the `hello` package, and runs the singular check.

Now, to get the actual BuildKite `pipeline.json`, run `nix eval --json
.#pipelines.buildkite`. This will produce a valid BuildKite pipeline, the
`--json` flag will print it out as JSON instead of Nix. You can use this in
combination with the BuildKite Agent CLI tool to upload the pipeline. E.g. to
use your own Nix flake with BuildKite, make sure the attribute
`pipelines.buildkite.steps` gets defined in the flake's outputs. And then run
the following command as a first step in the BuildKite pipeline.

```shell
nix eval .#pipelines.buildkite --json | buildkite-agent pipeline upload
```

You can look at [the example flake][example-flake], and how we set it up on
BuildKite.

## 👋 Hello from the Tweag team

[![Scale your engineering power][banner]][website]

At Tweag we love using open source methods and research ideas to improve
software quality and reliability. We are big on composable software: functional,
typed, immutable. You might have seen some of our work in your own favourite
technical community, or read some of our [articles][blog].

**We're hiring, globally**, so if you want to shape the future of the software
industry working with innovative clients and smart, friendly colleagues, [read
more here][careers]!

[banner]: .github/profile/banner.jpg
[website]: https://tweag.io/
[blog]: https://tweag.io/blog
[careers]: https://tweag.io/careers
[example-flake]: ./examples/flake.nix
